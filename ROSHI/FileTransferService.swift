import Foundation
import Network
import UIKit

enum TransferError: Error {
    case noReceiverFound
    case connectionFailed
    case sendFailed
    case fileNotFound
}

protocol FileTransferServiceDelegate: AnyObject {
    func transferProgress(_ progress: Double)
    func transferCompleted()
    func transferFailed(_ error: Error)
    func connectionStateChanged(_ isConnected: Bool)
}

class FileTransferService {
    weak var delegate: FileTransferServiceDelegate?
    
    private var connection: NWConnection?
    private let transferQueue = DispatchQueue(label: "transfer.queue")
    private var sendAttempts = 0
    private let maxSendAttempts = 10
    private var isConnected = false
    private var connectionCheckTimer: Timer?
    private let connectionCheckInterval: TimeInterval = 3.0 // Check every 3 seconds
    private var connectionStartTime: Date?
    private let connectionTimeout: TimeInterval = 5.0 // Timeout after 5 seconds of trying
    private var imuStartSignalSent: Bool = false // Track if start signal has been sent in this session
    private let startSignalLegacy: UInt8 = 2
    private let startSignalWithTimestamp: UInt8 = 4
    private let stopSignal: UInt8 = 3
    private let startSignalWithSession: UInt8 = 5
    private let stopSignalWithSession: UInt8 = 6
    private var currentSessionID: UUID?
    
    // Connection liveness
    // NWConnection can remain `.ready` after the remote process is killed unless we attempt a read/write.
    // We run a tiny receive loop to detect remote FIN/RST and update UI promptly.
    private var activeConnectionToken = UUID()
    private var receiveLoopStartedForToken: UUID?

    // Background task to keep file transfers alive when app is backgrounded
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // Direct connection
    var receiverHost: String = ""
    var receiverPort: UInt16 = 50000
    
    var receiverAddress: String {
        return "\(receiverHost):\(receiverPort)"
    }
    
    var connected: Bool {
        return isConnected
    }
    
    // Protocol:
    // Control signals:
    //   2 = start IMU recording (legacy, no timestamp)
    //   4 = start IMU recording with timestamp (8-byte unix ns, big-endian)
    //   3 = stop IMU recording
    //   5 = start IMU recording with timestamp + session UUID [0x05][ts_ns:8][uuid:16]
    //   6 = stop IMU recording with session UUID              [0x06][uuid:16]
    // File transfer (legacy, no session):
    //   type (1 byte: 0=video, 1=metadata) + name_len:4 + name + size:8 + data
    // File transfer (session-aware):
    //   type (1 byte: 10=video, 11=metadata) + uuid:16 + name_len:4 + name + size:8 + data
    
    private func connect(to endpoint: NWEndpoint) {
        // Cancel existing connection if any
        connection?.cancel()
        connection = nil
        activeConnectionToken = UUID()
        receiveLoopStartedForToken = nil
        
        let parameters = NWParameters.tcp
        
        connection = NWConnection(to: endpoint, using: parameters)
        connectionStartTime = Date()
        let token = activeConnectionToken
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            var newConnectedState = false
            
            switch state {
            case .setup:
                print("Connection setting up...")
            case .waiting(let error):
                print("Connection waiting: \(error)")
                // Check if we've been waiting too long
                if let startTime = self.connectionStartTime,
                   Date().timeIntervalSince(startTime) > self.connectionTimeout {
                    print("Connection timeout, cancelling and will retry...")
                    self.connection?.cancel()
                    self.connection = nil
                    self.connectionStartTime = nil
                }
            case .preparing:
                print("Connection preparing...")
            case .ready:
                print("✓ Connected to receiver")
                newConnectedState = true
                self.connectionStartTime = nil
                self.startReceiveLoopIfNeeded(token: token)
            case .failed(let error):
                print("✗ Connection failed: \(error)")
                self.connection = nil
                self.connectionStartTime = nil
                // Don't call transferFailed here as it might be a temporary connection issue
            case .cancelled:
                print("Connection cancelled")
                self.connection = nil
                self.connectionStartTime = nil
            @unknown default:
                print("Connection state: \(state)")
                break
            }
            
            // Notify delegate of connection state change
            if self.isConnected != newConnectedState {
                self.isConnected = newConnectedState
                // Reset IMU start signal flag when connection is lost
                if !newConnectedState {
                    self.imuStartSignalSent = false
                }
                DispatchQueue.main.async {
                    self.delegate?.connectionStateChanged(newConnectedState)
                }
            }
        }
        
        connection?.start(queue: transferQueue)
    }
    
    private func startReceiveLoopIfNeeded(token: UUID) {
        // Prevent multiple concurrent receive loops for the same connection instance.
        guard receiveLoopStartedForToken != token else { return }
        receiveLoopStartedForToken = token
        startReceiveLoop(token: token)
    }
    
    private func startReceiveLoop(token: UUID) {
        guard token == activeConnectionToken, let conn = connection else { return }
        
        // Receiver doesn't send data; we only use this to detect remote close/error promptly.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard token == self.activeConnectionToken else { return } // stale connection
            
            if let error = error {
                print("✗ Receive error (treat as disconnected): \(error)")
                conn.cancel()
                return
            }
            
            if isComplete {
                print("✗ Receiver closed connection (treat as disconnected)")
                conn.cancel()
                return
            }
            
            if let data, !data.isEmpty {
                print("ℹ Ignoring unexpected \(data.count) byte(s) from receiver")
            }
            
            self.startReceiveLoop(token: token)
        }
    }
    
    func connectDirect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        connect(to: endpoint)
    }
    
    // Send control signal to receiver (for IMU recording start)
    func sendControlSignal(_ signal: UInt8, timestampNs: UInt64? = nil, sessionID: UUID? = nil) {
        guard let conn = connection, conn.state == .ready else {
            print("⚠ Cannot send control signal: connection not ready")
            return
        }

        var payload = Data([signal])
        if let timestampNs = timestampNs {
            var beTimestamp = timestampNs.bigEndian
            withUnsafeBytes(of: &beTimestamp) { bytes in
                payload.append(contentsOf: bytes)
            }
        }
        if let sessionID = sessionID {
            let uuidBytes = sessionID.uuid
            withUnsafeBytes(of: uuidBytes) { bytes in
                payload.append(contentsOf: bytes)
            }
        }
        let signalName = controlSignalName(signal)
        let tsSuffix = timestampNs.map { " ts_ns=\($0)" } ?? ""
        let sidSuffix = sessionID.map { " session=\($0.uuidString)" } ?? ""
        print("📡 Sending control signal: \(signalName)\(tsSuffix)\(sidSuffix)")

        // Send immediately on the transfer queue for minimal delay
        transferQueue.async {
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error = error {
                    print("✗ Control signal send error: \(error)")
                } else {
                    print("✓ Control signal sent successfully")
                }
            })
        }
    }
    
    func sendStartRecordingSignal() {
        // Only send the signal once per connection session
        guard !imuStartSignalSent else {
            print("📡 IMU start signal already sent in this session, skipping...")
            return
        }

        // Generate session ID on first call; keep the same UUID across reconnects
        if currentSessionID == nil {
            currentSessionID = UUID()
        }

        let timestampNs = currentUnixTimeNs()
        sendControlSignal(startSignalWithSession, timestampNs: timestampNs, sessionID: currentSessionID)
        imuStartSignalSent = true
    }
    
    func sendStopRecordingSignal() {
        if let sid = currentSessionID {
            sendControlSignal(stopSignalWithSession, sessionID: sid)
        } else {
            sendControlSignal(stopSignal)
        }
    }

    private func controlSignalName(_ signal: UInt8) -> String {
        switch signal {
        case startSignalLegacy, startSignalWithTimestamp:
            return "START_IMU_RECORDING"
        case startSignalWithSession:
            return "START_IMU_RECORDING(session)"
        case stopSignal:
            return "STOP_IMU_RECORDING"
        case stopSignalWithSession:
            return "STOP_IMU_RECORDING(session)"
        default:
            return "UNKNOWN(\(signal))"
        }
    }

    private func currentUnixTimeNs() -> UInt64 {
        return UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
    
    func setReceiver(host: String, port: UInt16) {
        receiverHost = host
        receiverPort = port
        // Disconnect existing connection
        connection?.cancel()
        connection = nil
        isConnected = false
        // Reset IMU start signal flag and session when receiver is changed
        imuStartSignalSent = false
        currentSessionID = nil
        DispatchQueue.main.async {
            self.delegate?.connectionStateChanged(false)
        }
        // Try connecting immediately
        connectDirect(host: host, port: port)
        // Start periodic connection checks
        startConnectionChecks()
    }
    
    private func startConnectionChecks() {
        // Stop existing timer if any
        stopConnectionChecks()
        
        // Only start checks if we have a receiver configured
        guard !receiverHost.isEmpty else { return }
        
        connectionCheckTimer = Timer.scheduledTimer(withTimeInterval: connectionCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnection()
        }
    }
    
    func stopConnectionChecks() {
        connectionCheckTimer?.invalidate()
        connectionCheckTimer = nil
    }

    func resumeConnectionChecks() {
        guard !receiverHost.isEmpty else { return }
        // Immediately check once, then restart the periodic timer
        checkConnection()
        startConnectionChecks()
    }
    
    private func checkConnection() {
        // If we have a receiver configured, check connection status
        guard !receiverHost.isEmpty else {
            stopConnectionChecks()
            return
        }
        
        // Check if connection exists and is ready
        if let conn = connection {
            switch conn.state {
            case .ready:
                // Connection is good, update state if needed
                if !isConnected {
                    isConnected = true
                    DispatchQueue.main.async {
                        self.delegate?.connectionStateChanged(true)
                    }
                }
            case .failed, .cancelled:
                // Connection lost, try to reconnect
                print("Connection lost, attempting to reconnect...")
                connection = nil
                connectionStartTime = nil
                isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.connectionStateChanged(false)
                }
                connectDirect(host: receiverHost, port: receiverPort)
            case .waiting:
                // Check if we've been waiting too long (timeout)
                if let startTime = connectionStartTime,
                   Date().timeIntervalSince(startTime) > connectionTimeout {
                    print("Connection timeout in waiting state, cancelling and retrying...")
                    conn.cancel()
                    connection = nil
                    connectionStartTime = nil
                    isConnected = false
                    DispatchQueue.main.async {
                        self.delegate?.connectionStateChanged(false)
                    }
                    connectDirect(host: receiverHost, port: receiverPort)
                }
            case .setup, .preparing:
                // Connection in progress, wait (but check for timeout)
                if let startTime = connectionStartTime,
                   Date().timeIntervalSince(startTime) > connectionTimeout {
                    print("Connection timeout, cancelling and retrying...")
                    conn.cancel()
                    connection = nil
                    connectionStartTime = nil
                    isConnected = false
                    DispatchQueue.main.async {
                        self.delegate?.connectionStateChanged(false)
                    }
                    connectDirect(host: receiverHost, port: receiverPort)
                }
            @unknown default:
                break
            }
        } else {
            // No connection exists, try to connect
            if !isConnected {
                // Only log if we're not already trying to connect
                print("No connection exists, attempting to connect to \(receiverAddress)...")
            }
            isConnected = false
            DispatchQueue.main.async {
                self.delegate?.connectionStateChanged(false)
            }
            connectDirect(host: receiverHost, port: receiverPort)
        }
    }
    
    private func beginBackgroundTransferTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "FileTransfer") { [weak self] in
            // System is about to expire the task — clean up
            print("⚠ Background transfer time expired")
            self?.endBackgroundTransferTask()
        }
    }

    private func endBackgroundTransferTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func sendFiles(videoURL: URL, metadataURL: URL) {
        // Request background execution time so transfer survives app switching
        beginBackgroundTransferTask()

        // Reset attempts if we have a ready connection
        if connection?.state == .ready {
            sendAttempts = 0
        } else {
            sendAttempts += 1
            if sendAttempts >= maxSendAttempts {
                sendAttempts = 0
                print("✗ Max connection attempts reached")
                print("Files kept locally: \(videoURL.lastPathComponent)")
                delegate?.transferFailed(TransferError.connectionFailed)
                endBackgroundTransferTask()
                return
            }
        }

        // Ensure we have a receiver configured
        guard !receiverHost.isEmpty else {
            print("✗ No receiver configured")
            print("Files kept locally: \(videoURL.lastPathComponent)")
            delegate?.transferFailed(TransferError.connectionFailed)
            endBackgroundTransferTask()
            return
        }
        
        // Try to connect if not connected
        if connection == nil || connection?.state != .ready {
            print("Attempting connection to \(receiverAddress) (attempt \(sendAttempts)/\(maxSendAttempts))")
            connectDirect(host: receiverHost, port: receiverPort)
            // Wait a bit for connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.sendFiles(videoURL: videoURL, metadataURL: metadataURL)
            }
            return
        }
        
        sendAttempts = 0  // Reset on successful connection check
        print("Connection ready, starting file transfer...")

        // Capture session ID for this transfer batch
        let sessionID = currentSessionID

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            // Send video file first
            self.sendFile(url: videoURL, fileType: 0, sessionID: sessionID) { [weak self] success in
                guard let self = self else { return }
                if success {
                    DispatchQueue.main.async {
                        self.delegate?.transferProgress(0.5) // 50% after video
                    }
                    // Then send metadata
                    self.sendFile(url: metadataURL, fileType: 1, sessionID: sessionID) { [weak self] success in
                        guard let self = self else { return }
                        if success {
                            // Delete files only after BOTH transfers succeed
                            try? FileManager.default.removeItem(at: videoURL)
                            try? FileManager.default.removeItem(at: metadataURL)
                            // Clear session ID — this recording is fully delivered
                            self.currentSessionID = nil
                            DispatchQueue.main.async {
                                self.delegate?.transferProgress(1.0)
                                self.delegate?.transferCompleted()
                            }
                            self.endBackgroundTransferTask()
                            print("✓ Transfer complete. Files deleted: \(videoURL.lastPathComponent)")
                        } else {
                            // Keep files locally on metadata transfer failure
                            DispatchQueue.main.async {
                                self.delegate?.transferFailed(TransferError.sendFailed)
                            }
                            self.endBackgroundTransferTask()
                            print("✗ Metadata transfer failed. Files kept locally: \(videoURL.lastPathComponent)")
                        }
                    }
                } else {
                    // Keep files locally on video transfer failure
                    print("✗ Video transfer failed. Files kept locally: \(videoURL.lastPathComponent)")
                    DispatchQueue.main.async {
                        self.delegate?.transferFailed(TransferError.sendFailed)
                    }
                    self.endBackgroundTransferTask()
                }
            }
        }
    }
    
    private func sendFile(url: URL, fileType: UInt8, sessionID: UUID? = nil, completion: @escaping (Bool) -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(false)
            return
        }

        guard let fileData = try? Data(contentsOf: url) else {
            completion(false)
            return
        }

        let fileName = url.lastPathComponent
        guard let fileNameData = fileName.data(using: .utf8) else {
            completion(false)
            return
        }

        var message = Data()

        if let sessionID = sessionID {
            // Session-aware type: 10 = video, 11 = metadata
            let sessionType: UInt8 = (fileType == 0) ? 10 : 11
            message.append(sessionType)

            // 16-byte raw UUID
            let uuidBytes = sessionID.uuid
            withUnsafeBytes(of: uuidBytes) { bytes in
                message.append(contentsOf: bytes)
            }
        } else {
            // Legacy type: 0 = video, 1 = metadata
            message.append(fileType)
        }

        // Filename length (4 bytes, big-endian)
        var fileNameLength = UInt32(fileNameData.count).bigEndian
        withUnsafeBytes(of: &fileNameLength) { bytes in
            message.append(Data(bytes))
        }

        // Filename
        message.append(fileNameData)

        // File size (8 bytes, big-endian)
        var fileSize = UInt64(fileData.count).bigEndian
        withUnsafeBytes(of: &fileSize) { bytes in
            message.append(Data(bytes))
        }

        // File data
        message.append(fileData)
        
        print("Sending file: \(fileName) (\(fileData.count) bytes)")
        
        // Check connection state before sending
        guard let conn = connection, conn.state == .ready else {
            print("✗ Connection not ready for sending")
            completion(false)
            return
        }
        
        // Send in chunks for large files to avoid memory issues
        let chunkSize = 1024 * 1024  // 1MB chunks
        if message.count > chunkSize {
            print("Sending large file in chunks...")
            sendLargeFile(connection: conn, data: message, fileName: fileName, chunkSize: chunkSize, completion: completion)
        } else {
            conn.send(content: message, completion: .contentProcessed { error in
                if let error = error {
                    print("✗ Send error: \(error)")
                    completion(false)
                } else {
                    print("✓ File sent successfully: \(fileName)")
                    completion(true)
                }
            })
        }
    }
    
    private func sendLargeFile(connection: NWConnection, data: Data, fileName: String, chunkSize: Int, completion: @escaping (Bool) -> Void) {
        var offset = 0
        var hasError = false
        
        func sendNextChunk() {
            guard !hasError, offset < data.count else {
                if !hasError {
                    print("✓ File sent successfully: \(fileName)")
                    completion(true)
                }
                return
            }
            
            let remaining = data.count - offset
            let currentChunkSize = min(chunkSize, remaining)
            let chunk = data.subdata(in: offset..<(offset + currentChunkSize))
            
            connection.send(content: chunk, completion: .contentProcessed { error in
                if let error = error {
                    print("✗ Send error at offset \(offset): \(error)")
                    hasError = true
                    completion(false)
                } else {
                    offset += currentChunkSize
                    let progress = Double(offset) / Double(data.count) * 100
                    if offset % (5 * 1024 * 1024) < chunkSize {  // Progress every 5MB
                        print("  Progress: \(String(format: "%.1f", progress))% (\(offset)/\(data.count) bytes)")
                    }
                    sendNextChunk()
                }
            })
        }
        
        sendNextChunk()
    }
    
    func disconnect() {
        stopConnectionChecks()
        activeConnectionToken = UUID()
        receiveLoopStartedForToken = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        DispatchQueue.main.async {
            self.delegate?.connectionStateChanged(false)
        }
    }
}
