#!/bin/bash

# Port Manager Build Script
# Compiles the SwiftUI app into a macOS application bundle

set -e

APP_NAME="PortManager"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile the Swift file
echo "Compiling Swift code..."
swiftc -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    PortManager.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -parse-as-library \
    -O \
    -whole-module-optimization

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy app icon
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "Build complete: $APP_BUNDLE"
echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "Or run directly:"
echo "  $APP_BUNDLE/Contents/MacOS/$APP_NAME"
