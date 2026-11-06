"""Compile avatar_fenetres.dll avec Visual Studio, sans fenetre, et verifie qu'aucun chemin de ce PC n'y reste. Jeu ferme : il verrouille la DLL installee, pas celle-ci."""
import glob
import pathlib
import re
import subprocess
import sys
import tempfile

ICI = pathlib.Path(__file__).resolve().parent
SORTIE = ICI.parent / "mods" / "AvatarRules" / "avatar_fenetres.dll"
vcvars = glob.glob(r"C:\Program Files\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat")
if not vcvars:
    sys.exit("ECHEC : vcvars64.bat introuvable")
avant = SORTIE.stat().st_mtime if SORTIE.exists() else 0
with tempfile.TemporaryDirectory() as t:
    obj = pathlib.Path(t)
    commande = (
        f'"{vcvars[0]}" >nul && rc /nologo /fo"{obj / "v.res"}" "{ICI / "avatar_fenetres.rc"}" && '
        f'cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /utf-8 /LD "/d1trimfile:{ICI}\\\\" "{ICI / "avatar_fenetres.cpp"}" "{obj / "v.res"}" '
        f'/Fo"{obj}\\\\" /Fe"{SORTIE}" /link /NOLOGO /BREPRO /IMPLIB:"{obj / "v.lib"}"'
    )
    r = subprocess.run(commande, shell=True, capture_output=True, text=True, errors="replace", creationflags=subprocess.CREATE_NO_WINDOW)
lignes = (r.stdout + r.stderr).splitlines()
utile = [l for l in lignes if "error" in l.lower() or "warning" in l.lower()]
print("\n".join(utile[:15]))
if r.returncode != 0 or not SORTIE.exists() or SORTIE.stat().st_mtime == avant:
    print("\n".join(lignes[-6:]))
    sys.exit(f"ECHEC de la compilation, code {r.returncode}")
octets = SORTIE.read_bytes()
for motif in (rb"D:\\claude", rb"Users\\Demonwal", rb"spirit-city", rb"\.pdb"):
    if re.search(motif, octets, re.I):
        sys.exit("ECHEC : le binaire contient " + motif.decode())
print(f"OK {SORTIE.name} {len(octets)} octets")
