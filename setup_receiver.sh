#!/bin/bash
# Setup script for ROSHI receiver

echo "Setting up ROSHI receiver..."

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is not installed. Please install Python 3 first."
    exit 1
fi

echo "Python 3 found: $(python3 --version)"

# Create virtual environment (optional but recommended)
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
fi

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Install dependencies
echo "Installing dependencies..."
pip install -r requirements.txt

echo ""
echo "Setup complete!"
echo ""
echo "To run the receiver:"
echo "  source venv/bin/activate  # (if using virtual environment)"
echo "  python3 receiver.py"
echo ""
echo "Options:"
echo "  --port PORT        Specify port (default: auto)"
echo "  --output-dir DIR   Specify output directory (default: received_recordings)"
echo ""
