import os
import subprocess
import sys
import urllib.request

def download_file(url, filename):
    try:
        print(f"Downloading {filename}...")
        urllib.request.urlretrieve(url, filename)
        print(f"{filename} downloaded successfully.")
    except Exception as e:
        print(f"Error downloading {filename}: {e}")

def select_device_model():
    devices = {
        "1": "EA01J",
        "2": "CA01N",
        "3": "EB01M"
    }
    
    print("""
    ==============================================
                 Select Device Model
    ==============================================
    1. Energy 23 (EA01J)
    2. Social Voz (CA01N)
    3. Toro Shock (EB01M)
    4. Exit
    """)
    choice = input("Select an option: ")
    
    if choice in devices:
        download_firmware(devices[choice])
    elif choice == "4":
        main_menu()
    else:
        print("Invalid selection.")
        select_device_model()

def download_firmware(model):
    base_url = f"https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/{model}/"
    files = ["bootloader.bin", "partitions.bin", "firmware.bin"]
    
    for file in files:
        download_file(base_url + file, file)
    
    main_menu()

def flash_esp32():
    port = input("PORT (e.g., COM3): ")
    command = [sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", port, "erase_flash"]
    subprocess.run(command, check=False)
    main_menu()

def update_firmware_and_monitor():
    port = input("PORT (e.g., COM3): ")
    command = [
        sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", port, "--baud", "115200",
        "--before", "default_reset", "--after", "hard_reset", "write_flash", "-z", "--flash_mode", "dio",
        "--flash_freq", "40m", "--flash_size", "detect", "0x0", "bootloader.bin", "0x8000", "partitions.bin",
        "0x10000", "firmware.bin"
    ]
    subprocess.run(command, check=False)
    print("Firmware updated successfully. Now monitoring serial...")
    subprocess.run([sys.executable, "monitor_serial.py", port], check=False)
    main_menu()

def print_qr():
    if not os.path.exists("mac_qr.png"):
        print("QR code not found. Please run the serial monitor first.")
    else:
        subprocess.run([sys.executable, "print_qr.py"], check=False)
    main_menu()

def main_menu():
    print("""
    ==============================================
                 ESP32 Tools Menu
    ==============================================
    1. Flash
    2. Update Firmware and Monitor Serial
    3. Print QR Code
    4. Select Device Model
    5. Exit
    """)
    choice = input("Select an option: ")
    
    if choice == "1":
        flash_esp32()
    elif choice == "2":
        update_firmware_and_monitor()
    elif choice == "3":
        print_qr()
    elif choice == "4":
        select_device_model()
    elif choice == "5":
        sys.exit()
    else:
        print("Invalid option.")
        main_menu()

if __name__ == "__main__":
    main_menu()