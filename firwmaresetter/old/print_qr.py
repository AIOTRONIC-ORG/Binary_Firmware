import win32print
import win32ui
from PIL import Image, ImageWin

def get_printers():
    printers = win32print.EnumPrinters(2)
    return [printer[2] for printer in printers]

def print_image(printer_name, file_name):
    hDC = win32ui.CreateDC()
    hDC.CreatePrinterDC(printer_name)
    printer_size = hDC.GetDeviceCaps(110), hDC.GetDeviceCaps(111)

    bmp = Image.open(file_name)
    if bmp.size[0] > bmp.size[1]:
        bmp = bmp.rotate(90)

    hDC.StartDoc(file_name)
    hDC.StartPage()

    dib = ImageWin.Dib(bmp)
    dib.draw(hDC.GetHandleOutput(), (0, 0, printer_size[0], printer_size[1]))

    hDC.EndPage()
    hDC.EndDoc()
    hDC.DeleteDC()

if __name__ == "__main__":
    printers = get_printers()
    print("Available printers:")
    for i, printer in enumerate(printers, 1):
        print(f"{i}. {printer}")

    choice = int(input("Select a printer (enter the number): ")) - 1
    if 0 <= choice < len(printers):
        selected_printer = printers[choice]
        print(f"Printing to {selected_printer}")
        print_image(selected_printer, 'mac_qr.png')
        print("Printing complete.")
    else:
        print("Invalid selection.")
