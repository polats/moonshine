/*
 * steamwebhelper wrapper for Steam under Wine on Apple Silicon.
 *
 * Installed as steamwebhelper.exe next to Valve's original, renamed to
 * steamwebhelper_real.exe. Re-launches the original with extra Chromium
 * flags that Steam itself does not pass through:
 *
 *   --single-process  keeps rendering and networking in one process; the
 *                     split processes paint black and fail TLS under Wine
 *   --disable-gpu     CPU rasterisation; the GPU path crashes via MoltenVK
 *
 * Based on notpop/steam-on-m1-wine (MIT).
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <wchar.h>
#include <stdlib.h>

#define EXTRA_FLAGS L"--disable-gpu --single-process"
#define REAL_BINARY L"steamwebhelper_real.exe"

/* Skip argv[0] in the raw command line, preserving the remaining quoting. */
static const wchar_t *skip_program_name(const wchar_t *cmd)
{
    if (*cmd == L'"') {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd == L'"') cmd++;
    } else {
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    }
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR unused, int show)
{
    (void)inst; (void)prev; (void)unused; (void)show;

    wchar_t real[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (!slash || (size_t)(slash - real) + 1 + wcslen(REAL_BINARY) >= MAX_PATH) return 1;
    wcscpy(slash + 1, REAL_BINARY);

    const wchar_t *args = skip_program_name(GetCommandLineW());
    size_t size = wcslen(real) + wcslen(EXTRA_FLAGS) + wcslen(args) + 8;
    wchar_t *cmd = malloc(size * sizeof(wchar_t));
    if (!cmd) return 1;
    swprintf(cmd, size, L"\"%ls\" %ls %ls", real, EXTRA_FLAGS, args);

    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        free(cmd);
        return 1;
    }
    free(cmd);

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
