# SPDX-License-Identifier: AGPL-3.0-or-later
"""Check actual literal MSIX manifest assets without a resource-index fallback."""
from pathlib import Path
import shutil
import struct
import tempfile
import xml.etree.ElementTree as ET

CLIENT = Path(__file__).resolve().parents[2]
APP = CLIENT / "src/OpenWebPbx.Phone.App"
EXPECTED = {
    "StoreLogo.png": (50, 50),
    "Square150x150Logo.png": (150, 150),
    "Square44x44Logo.png": (44, 44),
    "Wide310x150Logo.png": (310, 150),
    "SplashScreen.png": (620, 300),
}


def inspect(app):
    tree = ET.parse(app / "Package.appxmanifest")
    references = []
    for node in tree.iter():
        if node.tag.rsplit("}", 1)[-1] == "Logo":
            references.append(node.text)
        references.extend(value for key, value in node.attrib.items()
                          if key in ("Square150x150Logo", "Square44x44Logo", "Wide310x150Logo", "Image"))
    if set(references) != {"Assets\\" + name for name in EXPECTED} or len(references) != len(EXPECTED):
        raise ValueError("unexpected manifest resources")
    for reference in references:
        path = app / reference.replace("\\", "/")
        if path.is_symlink() or not path.is_file() or not 24 <= path.stat().st_size <= 262144:
            raise ValueError("missing ordinary literal manifest resource")
        data = path.read_bytes()
        if data[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" or struct.unpack(">II", data[16:24]) != EXPECTED[path.name]:
            raise ValueError("incorrect PNG dimensions")


inspect(APP)
checks = 1
with tempfile.TemporaryDirectory(prefix="phone-manifest-assets-") as temp:
    fixture = Path(temp)
    shutil.copy(APP / "Package.appxmanifest", fixture / "Package.appxmanifest")
    shutil.copytree(APP / "Assets", fixture / "Assets")
    for name in EXPECTED:
        path = fixture / "Assets" / name
        original = path.read_bytes()
        path.unlink()
        try:
            inspect(fixture)
        except ValueError:
            checks += 1
        else:
            raise AssertionError("missing literal resource accepted")
        path.write_bytes(original[:16] + struct.pack(">II", 1, 1) + original[24:])
        try:
            inspect(fixture)
        except ValueError:
            checks += 1
        else:
            raise AssertionError("wrong resource dimensions accepted")
        path.write_bytes(original)
    inspect(fixture)
    checks += 1
print(f"PASS {checks} actual manifest/PNG/missing/dimension controls; native MakeAppx validation remains pending")
