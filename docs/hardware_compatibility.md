# Hardware compatibility

This document records what has been verified, what has been implemented but not
verified, and what is not supported. Nothing here claims a device was tested when
it was not.

## Verification status

No physical hardware was available in the development environment, which is a
Linux container. No printer, no barcode scanner and no Android device were
attached. Every statement below is therefore one of:

- **Verified by test** — covered by an automated test that exercises the code path.
- **Implemented, unverified** — the code is complete and compiles, but it has not
  run against the physical device.
- **Not supported** — no implementation exists, and the application reports this
  rather than failing silently.

## Barcode scanners

| Platform | Input | Status | Notes |
|---|---|---|---|
| Windows | USB HID keyboard-wedge scanner | **Verified by test** | `KeyboardWedgeScanner` reconstructs a scan from keystroke timing and an Enter terminator. Tests cover a valid EAN-13, duplicate suppression, and rejecting a burst that is too short. |
| Android | Camera (ML Kit) | **Implemented, unverified** | The adapter reports that the camera scanner is supplied by the scanning screen. No camera plugin is wired into a screen yet, and no device was available. Manual entry works. |
| Android | USB OTG scanner | **Not supported** | Falls back to manual entry. |
| Windows | Camera | **Not supported** | No camera adapter on desktop. Manual entry works. |
| Any | Manual entry | **Verified by test** | Always available, including when the platform scanner is unsupported. |

### Barcode formats

EAN-13, EAN-8, UPC-A, UPC-E, Code 128, Code 39 and QR Code are declared in
`BarcodeFormat`. The keyboard-wedge adapter labels a reading from its length and,
for 13-digit codes, validates the EAN-13 check digit. A wrong label never changes
which product is found, because lookup is by the scanned value itself.

## Printers

| Platform | Connection | Status | Notes |
|---|---|---|---|
| Any | Network (socket) | **Implemented, unverified** | The only transport that is the same on every platform. Currently returns a mock adapter until the socket transport is wired to a screen. |
| Android | Bluetooth | **Not supported yet** | Reports that the printer must be paired in system settings first. |
| Windows | Bluetooth | **Not supported yet** | Same as Android. |
| Windows | USB | **Not supported yet** | Reports that the printer must be shared and reachable. |
| Any | Virtual printer | **Verified by test** | `MockPrinterService` records every receipt and can be made to fail on demand, so the failure path is exercised without hardware. |

No specific printer model has been tested. The application must not be described
as compatible with a given model until it has been run against one.

## Receipt rendering

| Concern | Status |
|---|---|
| Plain-text ESC/POS layout | **Verified by test** — the byte stream is checked for the initialise command, the cut command, the cash-drawer pulse, and the presence of invoice figures. |
| Line wrapping | **Verified by test** — long names wrap at the paper width, and a single over-long word is hard-split rather than clipped. |
| Arabic detection | **Verified by test** — Arabic is detected across all printable fields, including presentation forms. |
| Arabic raster printing | **Verified by test** — an Arabic receipt is rendered to a 1-bit bitmap and produces visible ink, and the bitmap is accepted by the raster command with the right geometry. |
| Physical print on a real printer | **Not verified** — no printer was available. |

### Why Arabic is rasterised

Most ESC/POS printers have no Arabic code page. Sending Arabic as bytes produces
noise or question marks. The whole receipt is therefore rendered to a bitmap and
sent as an image, which also keeps column alignment consistent: a receipt that
mixed rasterised Arabic lines with text lines would have two different character
widths on one page.

The font used is Tajawal, bundled with the application, so the rendering does not
depend on a font being installed on the machine.

## Paper widths

| Width | Dots across | Characters per line |
|---|---|---|
| 58 mm | 384 | 32 |
| 80 mm | 576 | 48 |

The character counts are used for plain-text wrapping. The dot counts are used for
raster rendering. Both are verified by test.

## Platform support summary

| Capability | Android | Windows |
|---|---|---|
| Local database | Supported | Supported |
| Encrypted backup | Supported | Supported |
| Manual barcode entry | Supported | Supported |
| Camera barcode scanning | Implemented, unverified | Not supported |
| Keyboard-wedge scanning | Not applicable | **Verified by test** |
| Receipt rendering to bytes | Supported | Supported |
| Network printing | Implemented, unverified | Implemented, unverified |
| Bluetooth printing | Not supported yet | Not supported yet |
| USB printing | Not supported yet | Not supported yet |
