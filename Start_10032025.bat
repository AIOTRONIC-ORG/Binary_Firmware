  @echo off
  setlocal enabledelayedexpansion

  :: Define versions and tools
  set "python_version=3.11.4"
  set "python_installer=python-%python_version%-amd64.exe"
  set "tool=esptool"
  set "serial_tool=pyserial"
  set "qr_tool=qrcode[pil]"
  set "image_tool=Pillow"
  set "win32_tools=pywin32"

  :: Set up virtual environment
  set "venv_name=aiotronic_env"
  set "venv_path=%~dp0%venv_name%"
  set "venv_scripts=%venv_path%\Scripts"
  set "venv_python=%venv_scripts%\python.exe"
  set "venv_pip=%venv_scripts%\pip.exe"

  :: Check if Python is installed on the system
  python --version >nul 2>&1
  if %errorlevel% neq 0 (
      echo Python is not installed or not in the system PATH.
      echo Installing Python %python_version%...
      
      :: Download Python installer
      powershell -Command "(New-Object Net.WebClient).DownloadFile('https://www.python.org/ftp/python/%python_version%/%python_installer%', '%python_installer%')"
      
      :: Install Python
      %python_installer% /quiet InstallAllUsers=1 PrependPath=1 Include_test=0
      
      :: Clean up
      del %python_installer%
      
      echo Python %python_version% installed successfully.
      
      :: Refresh environment variables
      call refreshenv
  ) else (
      echo Python is already installed on the system.
  )

  :: Create virtual environment if it doesn't exist
  if not exist "%venv_path%" (
      echo Creating virtual environment...
      python -m venv "%venv_path%"
      if %errorlevel% neq 0 (
          echo Failed to create virtual environment. Please check your Python installation.
          pause
          exit /b 1
      )
      :: Hide the virtual environment folder
      attrib +h "%venv_path%"
  )

  :: Activate virtual environment
  call "%venv_scripts%\activate.bat"
  if %errorlevel% neq 0 (
      echo Failed to activate virtual environment.
      pause
      exit /b 1
  )

  :: Verify virtual environment activation
  "%venv_python%" -c "import sys; print(sys.prefix)"
  if %errorlevel% neq 0 (
      echo Error: Failed to activate virtual environment.
      pause
      exit /b 1
  )

  :: Upgrade pip in the virtual environment
  echo Upgrading pip...
  "%venv_python%" -m pip install --upgrade pip

  :: Install required tools
  echo Installing required tools...
  "%venv_pip%" install %tool% %serial_tool% %qr_tool% %image_tool% %win32_tools%

  :: Verify esptool installation
  "%venv_python%" -c "import esptool" 2>nul
  if %errorlevel% neq 0 (
      echo Error: esptool is not properly installed in the virtual environment.
      echo Attempting to reinstall esptool...
      "%venv_pip%" uninstall -y esptool
      "%venv_pip%" install esptool
  )

  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/monitor_serial.py', 'monitor_serial.py')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/AIOTRONIC-ORG/Binary_Firmware/main/print_qr.py', 'print_qr.py')"

  goto select_type_mode

  :select_type_mode
  cls
  echo ==============================================
  echo             Select Device Model
  echo ==============================================
  echo 1. Energy 23 (EA01J)
  echo 2. Social Voz (CA01N)
  echo 3. Toro Shock (EB01M)
  echo 4. Exit
  set /p choice_device_model="Select an option: "

  if "%choice_device_model%"=="1" goto download_energy_23_firmware
  if "%choice_device_model%"=="2" goto download_social_voz_firmware
  if "%choice_device_model%"=="3" goto download_toro_shock_firmware
  if "%choice_device_model%"=="4" (
      goto menu
  )
  cls


  :download_energy_23_firmware
  echo Downloading Latest Firmware (Energy 23)...
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EA01J/bootloader.bin', 'bootloader.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EA01J/partitions.bin', 'partitions.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EA01J/firmware.bin', 'firmware.bin')"
  goto menu

  :download_social_voz_firmware
  echo Downloading Latest Firmware (Social Voz)...
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/CA01N//bootloader.bin', 'bootloader.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/CA01N/partitions.bin', 'partitions.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/CA01N/firmware.bin', 'firmware.bin')"
  goto menu

  :download_toro_shock_firmware
  echo Downloading Latest Firmware (Toro Shock)...
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EB01M/bootloader.bin', 'bootloader.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EB01M/partitions.bin', 'partitions.bin')"
  powershell -Command "(New-Object Net.WebClient).DownloadFile('https://github.com/AIOTRONIC-ORG/Binary_Firmware/raw/main/EB01M/firmware.bin', 'firmware.bin')"
  goto menu

  :: Download the firmware files
  @REM echo Downloading Latest Firmware...

  :: Main Menu
  :menu
  cls
  echo ==============================================
  echo             ESP32 Tools Menu
  echo ==============================================
  echo 1. Flash
  echo 2. Update Firmware and Monitor Serial for MAC
  echo 3. Print QR Code
  echo 4. Select Device Model
  echo 5. Exit
  echo ==============================================
  set /p choice="Select an option: "

  if "%choice%"=="1" goto flash
  if "%choice%"=="2" goto update_firmware_and_monitor
  if "%choice%"=="3" goto print_qr
  if "%choice%"=="4" goto select_type_mode
  if "%choice%"=="5" (
      call "%venv_scripts%\deactivate.bat"
      exit
  )

  :: Option 1: Flash
  :flash
  cls
  set /p port="PORT (e.g., COM3): "
  "%venv_python%" -m esptool --chip esp32s3 --port COM%port% erase_flash
  if %errorlevel% neq 0 (
      echo Error: Failed to run the command with Python.
  )
  pause
  goto menu

  :: Option 2: Update Firmware and Monitor Serial for MAC
  :update_firmware_and_monitor
  cls
  set /p port="PORT (e.g., COM3): "
  "%venv_python%" -m esptool --chip esp32s3 --port COM%port% --baud 115200 --before default_reset --after hard_reset write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect 0x0 bootloader.bin 0x8000 partitions.bin 0x10000 firmware.bin
  if %errorlevel% neq 0 (
      echo Error: Failed to update firmware.
      goto menu
  )
  echo Firmware updated successfully. Now waiting for device reconnection and MAC address...
  "%venv_python%" monitor_serial.py COM%port%
  if %errorlevel% neq 0 (
      echo Error: Failed to monitor the serial port.
      pause
  )
  pause
  goto menu

  :: Option 3: Print QR Code
  :print_qr
  cls
  if not exist mac_qr.png (
      echo QR code not found. Please run the serial monitor to generate it.
      pause
      goto menu
  )
  echo Printing mac_qr.png...
  python print_qr.py
  pause
  goto menu
