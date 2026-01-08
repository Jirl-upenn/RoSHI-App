import Foundation
import Network

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
    
    // Direct connection
    var receiverHost: String = ""
    var receiverPort: UInt16 = 50000
    
    var receiverAddress: String {
        return "\(receiverHost):\(receiverPort)"
    }
    
    var connected: Bool {
        return isConnected
    }
    
    // Simple protocol:
    // 1. Send file type (1 byte: 0=video, 1=metadata)
    // 2. Send filename length (4 bytes, big-endian)
    // 3. Send filename (UTF-8)
    // 4. Send file size (8 bytes, big-endian)
    // 5. Send file data
    
    private func connect(to endpoint: NWEndpoint) {
        // Cancel existing connection if any
        connection?.cancel()
        connection = nil
        
        let parameters = NWParameters.tcp
        
        connection = NWConnection(to: endpoint, using: parameters)
        connectionStartTime = Date()
        
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
                DispatchQueue.main.async {
                    self.delegate?.connectionStateChanged(newConnectedState)
                }
            }
        }
        
        connection?.start(queue: transferQueue)
    }
    
    func connectDirect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        connect(to: endpoint)
    }
    
    func setReceiver(host: String, port: UInt16) {
        receiverHost = host
        receiverPort = port
        // Disconnect existing connection
        connection?.cancel()
        connection = nil
        isConnected = false
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
    
    private func stopConnectionChecks() {
        connectionCheckTimer?.invalidate()
        connectionCheckTimer = nil
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
    
    func sendFiles(videoURL: URL, metadataURL: URL) {
        // Reset attempts if we have a ready connection
        if connection?.state == .ready {
            sendAttempts = 0
        } else {
            sendAttempts += 1
            if sendAttempts >= maxSendAttempts {
                sendAttempts = 0
                print("✗ Max connection attempts reached")
                // Delete files even on failure
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.removeItem(at: metadataURL)
                print("Files deleted after transfer failure")
                delegate?.transferFailed(TransferError.connectionFailed)
                return
            }
        }
        
        // Ensure we have a receiver configured
        guard !receiverHost.isEmpty else {
            print("✗ No receiver configured")
            // Delete files even on failure
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: metadataURL)
            print("Files deleted after transfer failure")
            delegate?.transferFailed(TransferError.connectionFailed)
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
        
        transferQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Send video file first
            self.sendFile(url: videoURL, fileType: 0) { [weak self] success in
                guard let self = self else { return }
                if success {
                    DispatchQueue.main.async {
                        self.delegate?.transferProgress(0.5) // 50% after video
                    }
                    // Then send metadata
                    self.sendFile(url: metadataURL, fileType: 1) { [weak self] success in
                        guard let self = self else { return }
                        // Delete files regardless of success/failure
                        try? FileManager.default.removeItem(at: videoURL)
                        try? FileManager.default.removeItem(at: metadataURL)
                        
                        if success {
                            DispatchQueue.main.async {
                                self.delegate?.transferProgress(1.0)
                                self.delegate?.transferCompleted()
                            }
                            print("Files deleted after successful transfer")
                        } else {
                            DispatchQueue.main.async {
                                self.delegate?.transferFailed(TransferError.sendFailed)
                            }
                            print("Files deleted after transfer failure")
                        }
                    }
                } else {
                    // Delete files on video send failure
                    try? FileManager.default.removeItem(at: videoURL)
                    try? FileManager.default.removeItem(at: metadataURL)
                    print("Files deleted after transfer failure")
                    DispatchQueue.main.async {
                        self.delegate?.transferFailed(TransferError.sendFailed)
                    }
                }
            }
        }
    }
    
    private func sendFile(url: URL, fileType: UInt8, completion: @escaping (Bool) -> Void) {
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
        
        // 1. File type (1 byte)
        message.append(fileType)
        
        // 2. Filename length (4 bytes, big-endian)
        var fileNameLength = UInt32(fileNameData.count).bigEndian
        withUnsafeBytes(of: &fileNameLength) { bytes in
            message.append(Data(bytes))
        }
        
        // 3. Filename
        message.append(fileNameData)
        
        // 4. File size (8 bytes, big-endian)
        var fileSize = UInt64(fileData.count).bigEndian
        withUnsafeBytes(of: &fileSize) { bytes in
            message.append(Data(bytes))
        }
        
        // 5. File data
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
        connection?.cancel()
        connection = nil
        isConnected = false
        DispatchQueue.main.async {
            self.delegate?.connectionStateChanged(false)
        }
    }
}
