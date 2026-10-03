#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

static void write_marker(const wchar_t *path, const char *text)
{
    DWORD written = 0;
    HANDLE h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, text, (DWORD)lstrlenA(text), &written, NULL);
    CloseHandle(h);
}

static HANDLE start_services_hidden(void)
{
    wchar_t system_dir[MAX_PATH], services[MAX_PATH];
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    if (!GetSystemDirectoryW(system_dir, MAX_PATH)) return NULL;
    lstrcpynW(services, system_dir, MAX_PATH);
    if (lstrlenW(services) + 14 >= MAX_PATH) return NULL;
    lstrcatW(services, L"\\services.exe");
    ZeroMemory(&si, sizeof(si)); ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    if (!CreateProcessW(services, NULL, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                        NULL, NULL, &si, &pi))
        return NULL;
    CloseHandle(pi.hThread);
    return pi.hProcess;
}

/* Use upstream Wine SCM readiness. */
static BOOL wait_for_services_ready(HANDLE started_event, HANDLE services_process)
{
    HANDLE handles[2];
    DWORD count = 1, status;
    if (!started_event) return FALSE;
    handles[0] = started_event;
    if (services_process) handles[count++] = services_process;
    status = WaitForMultipleObjects(count, handles, FALSE, 3500);
    return status == WAIT_OBJECT_0;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show)
{
    static const wchar_t *candidates[] = {
        L"C:\\Program Files (x86)\\Steam\\steam.exe",
        L"C:\\Program Files\\Steam\\steam.exe"
    };
    /* Product launch: go directly to Steam's controller-first UI. Keep CEF
     * software compositing for the currently proven Madeira login/Big Picture
     * path, but never create Steam's developer console window. */
    static const wchar_t args[] =
        L" -gamepadui -no-cef-sandbox -cef-disable-gpu -nocrashmonitor"
        L" -cef-disable-features=SegmentationPlatform,OptimizationTargetPrediction,OptimizationHints";
    const wchar_t *steam = NULL;
    wchar_t cwd[MAX_PATH], cmd[2048];
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    DWORD exit_code = 1; int i;
    (void)instance; (void)previous; (void)command_line; (void)show;

    DeleteFileW(L"C:\\.steamios-steam-launched");
    DeleteFileW(L"C:\\.steamios-steam-exit-code");
    DeleteFileW(L"C:\\.steamios-steam-launch-error");

    for (i = 0; i < (int)(sizeof(candidates) / sizeof(candidates[0])); ++i) {
        DWORD attr = GetFileAttributesW(candidates[i]);
        if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) {
            steam = candidates[i]; break;
        }
    }
    if (!steam) {
        write_marker(L"C:\\.steamios-steam-launch-error", "steam.exe not found\r\n");
        return 2;
    }

    {
        HANDLE started_event = CreateEventW(NULL, TRUE, FALSE, L"__wine_SvcctlStarted");
        HANDLE services_process;
        BOOL services_ready;
        if (!started_event) return 5;
        ResetEvent(started_event);
        services_process = start_services_hidden();
        services_ready = services_process && wait_for_services_ready(started_event, services_process);
        if (services_process) CloseHandle(services_process);
        CloseHandle(started_event);
        if (!services_ready) {
            write_marker(L"C:\\.steamios-steam-launch-error", "Wine Service Control Manager did not become ready\r\n");
            return 5;
        }
    }
    lstrcpynW(cwd, steam, MAX_PATH);
    { wchar_t *slash = wcsrchr(cwd, L'\\'); if (slash) *slash = 0; }

    cmd[0] = L'"'; cmd[1] = 0;
    lstrcatW(cmd, steam); lstrcatW(cmd, L"\""); lstrcatW(cmd, args);
    ZeroMemory(&si, sizeof(si)); ZeroMemory(&pi, sizeof(pi)); si.cb = sizeof(si);

    if (!CreateProcessW(steam, cmd, NULL, NULL, FALSE, 0, NULL, cwd, &si, &pi)) {
        write_marker(L"C:\\.steamios-steam-launch-error", "CreateProcessW steam.exe failed\r\n");
        return 3;
    }

    CloseHandle(pi.hThread);
    write_marker(L"C:\\.steamios-steam-launched", "Steam launch committed\r\n");
    WaitForSingleObject(pi.hProcess, INFINITE);
    if (!GetExitCodeProcess(pi.hProcess, &exit_code)) exit_code = 4;
    CloseHandle(pi.hProcess);
    { char text[32]; wsprintfA(text, "%lu\r\n", (unsigned long)exit_code);
      write_marker(L"C:\\.steamios-steam-exit-code", text); }
    return (int)exit_code;
}
