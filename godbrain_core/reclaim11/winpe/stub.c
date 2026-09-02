/* IFEO / offline stub: valid PE, exit 0, no console. Not a .cmd renamed to .exe. */
#include <windows.h>
void __stdcall mainCRTStartup(void) { ExitProcess(0); }
