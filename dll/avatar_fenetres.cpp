// avatar_fenetres.dll: tells the Avatar Rules mod which programs have a window open, on which screen, and whether
// that window is in front on its screen. The Lua side cannot see this, and starting a helper program from Lua would
// flash a console window in front of whatever the player is doing.
//
// That is all it does. It reads no window title and no window content, no keyboard and no mouse. It hooks nothing,
// touches nothing in the game, writes only one file next to itself, and has no network code.
//
// Files next to the DLL:
//   demande_fenetres.txt   request from the Lua mod: answer once. No request, no work.
//   fenetres.txt           the answer: E <screen> <size>, then A <program> <screen> <devant|derriere|reduite>
#include <windows.h>
#include <dwmapi.h>

#include <map>
#include <string>
#include <vector>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "dwmapi.lib")

namespace {

std::wstring g_dossier;

std::string VersUtf8(const std::wstring& t) {
    if (t.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, t.c_str(), static_cast<int>(t.size()), nullptr, 0, nullptr, nullptr);
    std::string r(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, t.c_str(), static_cast<int>(t.size()), r.data(), n, nullptr, nullptr);
    return r;
}

std::wstring ProgrammeDeFenetre(HWND h) {
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!p) return L"";
    wchar_t chemin[MAX_PATH];
    DWORD taille = MAX_PATH;
    std::wstring r;
    if (QueryFullProcessImageNameW(p, 0, chemin, &taille)) {
        r = chemin;
        r = r.substr(r.find_last_of(L'\\') + 1);
    }
    CloseHandle(p);
    return r;
}

// \\.\DISPLAY2 is screen 2: the number Windows shows, and the one the Real Screen mod shows too.
int NumeroEcran(HMONITOR m) {
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(m, &info)) return 0;
    int numero = 0;
    swscanf_s(info.szDevice, L"\\\\.\\DISPLAY%d", &numero);
    return numero;
}

BOOL CALLBACK RappelEcran(HMONITOR m, HDC, LPRECT r, LPARAM l) {
    auto* texte = reinterpret_cast<std::string*>(l);
    char ligne[64];
    snprintf(ligne, sizeof(ligne), "E\t%d\t%ldx%ld\n", NumeroEcran(m), r->right - r->left, r->bottom - r->top);
    *texte += ligne;
    return TRUE;
}

struct Parcours {
    std::string texte;
    std::map<int, bool> devant_vu;
};

// A window the player would call a window: not hidden, not owned by another one, not a tool strip or an overlay, and not the desktop.
bool VraieFenetre(HWND h) {
    if (!IsWindowVisible(h) || GetWindow(h, GW_OWNER)) return false;
    const LONG_PTR style = GetWindowLongPtrW(h, GWL_EXSTYLE);
    if (style & (WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE)) return false;
    DWORD masquee = 0;
    DwmGetWindowAttribute(h, DWMWA_CLOAKED, &masquee, sizeof(masquee));
    if (masquee) return false;
    if (GetWindowTextLengthW(h) == 0) return false;  // only its length: the title itself is never read
    wchar_t classe[64];
    if (GetClassNameW(h, classe, 64)) {
        for (const wchar_t* bureau : {L"Progman", L"WorkerW", L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd"}) {
            if (wcscmp(classe, bureau) == 0) return false;
        }
    }
    return true;
}

// Windows lists the windows from front to back: the first real one met on a screen is the one in front there.
BOOL CALLBACK RappelFenetre(HWND h, LPARAM l) {
    auto* p = reinterpret_cast<Parcours*>(l);
    if (!VraieFenetre(h)) return TRUE;
    const std::wstring programme = ProgrammeDeFenetre(h);
    if (programme.empty()) return TRUE;
    int ecran = 0;
    const char* etat = "derriere";
    if (IsIconic(h)) {
        // Minimized: it stays counted on the screen it goes back to.
        WINDOWPLACEMENT w{};
        w.length = sizeof(w);
        if (GetWindowPlacement(h, &w)) ecran = NumeroEcran(MonitorFromRect(&w.rcNormalPosition, MONITOR_DEFAULTTONEAREST));
        etat = "reduite";
    } else {
        RECT r{};
        GetWindowRect(h, &r);
        if (r.right <= r.left || r.bottom <= r.top) return TRUE;
        ecran = NumeroEcran(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST));
        if (!p->devant_vu[ecran]) {
            p->devant_vu[ecran] = true;
            etat = "devant";
        }
    }
    p->texte += "A\t" + VersUtf8(programme) + "\t" + std::to_string(ecran) + "\t" + etat + "\n";
    return TRUE;
}

void EcrireListe() {
    Parcours p;
    EnumDisplayMonitors(nullptr, nullptr, RappelEcran, reinterpret_cast<LPARAM>(&p.texte));
    EnumWindows(RappelFenetre, reinterpret_cast<LPARAM>(&p));
    const std::wstring fichier = g_dossier + L"fenetres.txt", tmp = fichier + L".tmp";
    HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD ecrits = 0;
    WriteFile(f, p.texte.data(), static_cast<DWORD>(p.texte.size()), &ecrits, nullptr);
    CloseHandle(f);
    MoveFileExW(tmp.c_str(), fichier.c_str(), MOVEFILE_REPLACE_EXISTING);
}

DWORD WINAPI Boucle(LPVOID) {
    const std::wstring demande = g_dossier + L"demande_fenetres.txt";
    for (;;) {
        Sleep(500);
        if (GetFileAttributesW(demande.c_str()) != INVALID_FILE_ATTRIBUTES) {
            DeleteFileW(demande.c_str());
            EcrireListe();
        }
    }
}

}  // namespace

BOOL WINAPI DllMain(HINSTANCE module, DWORD raison, LPVOID) {
    if (raison == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        wchar_t chemin[MAX_PATH];
        GetModuleFileNameW(module, chemin, MAX_PATH);
        g_dossier = chemin;
        g_dossier = g_dossier.substr(0, g_dossier.find_last_of(L'\\') + 1);
        // No request can come before a file of the last session is cleared.
        DeleteFileW((g_dossier + L"demande_fenetres.txt").c_str());
        DeleteFileW((g_dossier + L"fenetres.txt").c_str());
        HANDLE fil = CreateThread(nullptr, 0, Boucle, nullptr, 0, nullptr);
        if (fil) CloseHandle(fil);
    }
    return TRUE;
}
