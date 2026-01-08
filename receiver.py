#!/usr/bin/env python3
"""
ROSHI Video Receiver
Receives video and metadata files from iOS app over LAN
"""

import socket
import struct
import os
import json
from datetime import datetime
from zeroconf import ServiceInfo, Zeroconf
import threading

class ROSHIReceiver:
    def __init__(self, port=0, output_dir="received_recordings"):
        self.port = port
        self.output_dir = output_dir
        self.zeroconf = None
        self.service_info = None
        self.server_socket = None
        self.running = False
        
        # Create output directory if it doesn't exist
        os.makedirs(output_dir, exist_ok=True)
        
    def start(self):
        """Start the receiver service"""
        # Find an available port
        if self.port == 0:
            self.port = self._find_free_port()
        
        print(f"Starting ROSHI receiver on port {self.port}")
        
        # Start Bonjour service advertisement
        self._advertise_service()
        
        # Start TCP server
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind(('', self.port))
        self.server_socket.listen(5)
        self.server_socket.settimeout(1.0)  # Allow checking running flag
        
        self.running = True
        print(f"Receiver ready. Waiting for connections...")
        print(f"Files will be saved to: {os.path.abspath(self.output_dir)}")
        
        try:
            while self.running:
                try:
                    client_socket, address = self.server_socket.accept()
                    print(f"\nConnection from {address[0]}:{address[1]}")
                    # Handle each connection in a separate thread
                    client_thread = threading.Thread(
                        target=self._handle_client,
                        args=(client_socket, address)
                    )
                    client_thread.daemon = True
                    client_thread.start()
                except socket.timeout:
                    continue
                except Exception as e:
                    if self.running:
                        print(f"Error accepting connection: {e}")
        except KeyboardInterrupt:
            print("\nShutting down...")
        finally:
            self.stop()
    
    def _find_free_port(self):
        """Find an available port"""
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(('', 0))
            return s.getsockname()[1]
    
    def _advertise_service(self):
        """Advertise this service via Bonjour/mDNS"""
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
        
        # Get all local IPs (in case hostname doesn't resolve correctly)
        try:
            # Try to get the actual local IP
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()
        except:
            pass
        
        service_type = "_roshi._tcp.local."
        service_name = f"ROSHI Receiver.{service_type}"
        
        self.zeroconf = Zeroconf()
        
        self.service_info = ServiceInfo(
            service_type,
            service_name,
            addresses=[socket.inet_aton(local_ip)],
            port=self.port,
            properties={},
            server=f"{hostname}.local."
        )
        
        self.zeroconf.register_service(self.service_info)
        print(f"Service advertised as: {service_name}")
        print(f"IP: {local_ip}, Port: {self.port}")
    
    def _handle_client(self, client_socket, address):
        """Handle a client connection"""
        try:
            # Disable timeout - wait indefinitely for data
            client_socket.settimeout(None)
            session_folder = None  # Will be created when first file (video) is received
            
            print(f"  Waiting for data from {address[0]}...")
            
            while True:
                # Receive first byte to determine if it's a control signal or file type
                first_byte_data = self._recv_exact(client_socket, 1)
                if not first_byte_data:
                    print("  No more data, closing connection")
                    break
                
                first_byte = first_byte_data[0]
                
                # Check if it's a control signal
                if first_byte == 2:
                    print("  📡 Control Signal: START_IMU_RECORDING (signal 2)")
                    # Continue to next message
                    continue
                elif first_byte == 3:
                    print("  📡 Control Signal: STOP_IMU_RECORDING (signal 3)")
                    # Continue to next message
                    continue
                
                # Otherwise, it's a file type (0 = video, 1 = metadata)
                file_type = first_byte
                file_type_name = "video" if file_type == 0 else "metadata"
                print(f"  Receiving {file_type_name} file...")
                
                # Receive filename length (4 bytes, big-endian)
                filename_length_data = self._recv_exact(client_socket, 4)
                if not filename_length_data:
                    break
                
                filename_length = struct.unpack('>I', filename_length_data)[0]
                
                # Receive filename
                filename_data = self._recv_exact(client_socket, filename_length)
                if not filename_data:
                    break
                
                filename = filename_data.decode('utf-8')
                print(f"  Filename: {filename}")
                
                # Receive file size (8 bytes, big-endian)
                file_size_data = self._recv_exact(client_socket, 8)
                if not file_size_data:
                    break
                
                file_size = struct.unpack('>Q', file_size_data)[0]
                print(f"  File size: {file_size:,} bytes")
                
                # Receive file data in chunks for large files
                print(f"  Receiving {file_size:,} bytes...")
                file_data = b''
                bytes_received = 0
                chunk_size = 1024 * 1024  # 1MB chunks
                
                # Timeout already disabled - will wait indefinitely
                
                while bytes_received < file_size:
                    remaining = file_size - bytes_received
                    to_read = min(chunk_size, remaining)
                    
                    chunk = self._recv_exact(client_socket, to_read)
                    if not chunk:
                        print(f"  ✗ Connection closed unexpectedly at {bytes_received}/{file_size} bytes")
                        return
                    
                    file_data += chunk
                    bytes_received += len(chunk)
                    
                    # Progress update for large files
                    if file_size > 10 * 1024 * 1024:  # For files > 10MB
                        progress = (bytes_received / file_size) * 100
                        if bytes_received % (5 * 1024 * 1024) < chunk_size:  # Every 5MB
                            print(f"  Progress: {progress:.1f}% ({bytes_received:,}/{file_size:,} bytes)")
                
                if len(file_data) != file_size:
                    print(f"  ✗ Size mismatch: expected {file_size}, got {len(file_data)}")
                    break
                
                # Create session folder when receiving video (first file)
                if file_type == 0 and session_folder is None:
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                    session_folder = os.path.join(self.output_dir, f"recording_{timestamp}")
                    os.makedirs(session_folder, exist_ok=True)
                    print(f"  Created session folder: {session_folder}")
                
                # Use existing session folder if metadata comes first (shouldn't happen, but handle it)
                if file_type == 1 and session_folder is None:
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                    session_folder = os.path.join(self.output_dir, f"recording_{timestamp}")
                    os.makedirs(session_folder, exist_ok=True)
                    print(f"  Created session folder: {session_folder}")
                
                # Save file in session folder
                if file_type == 0:  # Video
                    # Keep original extension
                    ext = os.path.splitext(filename)[1] or '.mp4'
                    output_filename = f"video{ext}"
                else:  # Metadata
                    output_filename = "metadata.json"
                
                output_path = os.path.join(session_folder, output_filename)
                
                with open(output_path, 'wb') as f:
                    f.write(file_data)
                
                print(f"  ✓ Saved to: {output_path}")
                
                # If it's metadata, also print a summary
                if file_type == 1:
                    try:
                        metadata = json.loads(file_data.decode('utf-8'))
                        frame_count = len(metadata)
                        print(f"  ✓ Metadata contains {frame_count} frames")
                    except:
                        pass
                
        except Exception as e:
            print(f"  Error handling client {address[0]}: {e}")
        finally:
            client_socket.close()
            print(f"  Connection closed")
    
    def _recv_exact(self, sock, size):
        """Receive exactly 'size' bytes"""
        data = b''
        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                return None
            data += chunk
        return data
    
    def stop(self):
        """Stop the receiver service"""
        self.running = False
        if self.server_socket:
            self.server_socket.close()
        if self.zeroconf and self.service_info:
            self.zeroconf.unregister_service(self.service_info)
            self.zeroconf.close()
        print("Receiver stopped")

def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='ROSHI Video Receiver')
    parser.add_argument('--port', type=int, default=50000,
                       help='Port to listen on (default: 50000)')
    parser.add_argument('--output-dir', type=str, default='received_recordings',
                       help='Directory to save received files')
    
    args = parser.parse_args()
    
    receiver = ROSHIReceiver(port=args.port, output_dir=args.output_dir)
    
    try:
        receiver.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
        receiver.stop()

if __name__ == '__main__':
    main()
