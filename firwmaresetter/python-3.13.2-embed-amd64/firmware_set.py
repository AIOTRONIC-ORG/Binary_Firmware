import os
import subprocess
import sys
import urllib.request
import serial
import time
from datetime import datetime
from serial.tools import list_ports

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


    print("Buscando puertos disponibles...\n")
    ports = list_ports.comports()

    if not ports:
        print("No se encontraron puertos COM.")
        main_menu()
        return

    print("Puertos disponibles:")
    for i, port in enumerate(ports, start=1):
        desc = port.description
        hwid = port.hwid
        print(f"{i}. {port.device} - {desc} [{hwid}]")

    try:
        selection = int(input("\nSelecciona el número del puerto que quieres usar: "))
        selected_port = ports[selection - 1].device
    except (ValueError, IndexError):
        print("Selección inválida.")
        main_menu()
        return
    
    # port = input("PORT (e.g., COM3): ")
    command = [sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", selected_port, "erase_flash"]
    subprocess.run(command, check=False)
    main_menu()

def update_firmware_and_monitor():
    # port = input("PORT (e.g., COM3): ")
    print("Buscando puertos disponibles...\n")
    ports = list_ports.comports()

    if not ports:
        print("No se encontraron puertos COM.")
        main_menu()
        return

    print("Puertos disponibles:")
    for i, port in enumerate(ports, start=1):
        desc = port.description
        hwid = port.hwid
        print(f"{i}. {port.device} - {desc} [{hwid}]")

    try:
        selection = int(input("\nSelecciona el número del puerto que quieres usar: "))
        selected_port = ports[selection - 1].device
    except (ValueError, IndexError):
        print("Selección inválida.")
        main_menu()
        return
    
    command = [
        sys.executable, "-m", "esptool", "--chip", "esp32s3", "--port", selected_port, "--baud", "115200",
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



def view_serial_and_log():
    print("Buscando puertos disponibles...\n")
    ports = list_ports.comports()

    if not ports:
        print("No se encontraron puertos COM.")
        main_menu()
        return

    print("Puertos disponibles:")
    for i, port in enumerate(ports, start=1):
        desc = port.description
        hwid = port.hwid
        print(f"{i}. {port.device} - {desc} [{hwid}]")

    try:
        selection = int(input("\nSelecciona el número del puerto que quieres usar: "))
        selected_port = ports[selection - 1].device
    except (ValueError, IndexError):
        print("Selección inválida.")
        main_menu()
        return

    baud = 460800
    log_file = "serial_log.txt"

    try:
        with serial.Serial(selected_port, baud, timeout=1) as ser, open(log_file, "a", encoding="utf-8") as f:
            print(f"Monitoreando {selected_port}... (Presiona Ctrl+C para detener)")
            from datetime import datetime
            f.write(f"\n\n--- Serial session started at {datetime.now()} ---\n")
            while True:
                line = ser.readline()
                if line:
                    decoded_line = line.decode(errors="ignore").rstrip()
                    print(decoded_line)
                    f.write(decoded_line + "\n")
    except KeyboardInterrupt:
        print("\nMonitoreo detenido por el usuario.")
    except Exception as e:
        print(f"Error: {e}")
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
    6. Ver Monitor Serial
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
    elif choice == "6":
        view_serial_and_log()
    else:
        print("Invalid option.")
        main_menu()

if __name__ == "__main__":
    main_menu()
