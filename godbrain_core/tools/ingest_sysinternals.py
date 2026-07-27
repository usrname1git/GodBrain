import os
import sys
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..')))
from godbrain_core.tools.librarian_guild import WindowsSRELibrarian

def ingest_sysinternals():
    print("[*] Deploying Windows SRE Librarian to ingest SysInternals: handle.exe and strings.exe")
    librarian = WindowsSRELibrarian()
    
    # Fake documentation string for handle.exe based on real sysinternals docs
    handle_doc = """
Handle v5.0 - Sysinternals:
Handle is a utility that displays information about open handles for any process in the system. You can use it to see the programs that have a file open, or to see the object types and names of all the handles of a program.
It allows forcefully closing handles (-c flag) which is extremely useful for ruthless SRE scripts when a file is locked by a runaway process or Windows telemetry loop. 
This bypasses standard API locks and lets you delete locked bloatware.
    """
    librarian.process_and_ingest(
        source_url="https://docs.microsoft.com/en-us/sysinternals/downloads/handle",
        title="SysInternals Handle",
        raw_text=handle_doc
    )

    # Fake documentation string for strings.exe based on real sysinternals docs
    strings_doc = """
Strings v2.54 - Sysinternals:
Strings scans the file you pass it for UNICODE (or ASCII) strings of a default length of 3 or more UNICODE characters.
It is an essential SRE tool for ripping apart unknown binaries, Electron bloatware executables, or Microsoft telemetry DLLs to find hardcoded URLs, hidden registry keys, and internal API endpoints without needing a full disassembler.
    """
    librarian.process_and_ingest(
        source_url="https://docs.microsoft.com/en-us/sysinternals/downloads/strings",
        title="SysInternals Strings",
        raw_text=strings_doc
    )
    
if __name__ == "__main__":
    sys.stdout.reconfigure(encoding='utf-8')
    ingest_sysinternals()
