// Closer: the window's close button and Alt+F4 end Klass of 99.
//
// The game's engine gives its window a class marked "no close", which also greys out
// Close in the window's menu, and Wine drops a close request for a window like that.
// So the title bar's close button and the desktop's Alt+F4 never reach the game at
// all, and it only leaves through Quit on its title screen.
//
// Closer.exe starts the game and puts Closer.dll on the thread that owns the game's
// window. The DLL runs for every message that thread takes off its queue. It keeps
// closing allowed, and when a message asks the window to close it leaves the game the
// way a player would, with the game's own keys, so the game saves its settings as it
// does on Quit. A game that is still there a few seconds later is ended.
//
// This file builds both halves; CLOSER_DLL selects the DLL. Build with
// tools/build-closer.sh.
#include <windows.h>

#ifdef CLOSER_DLL

static HWND game_window;

// A message that asks the window to close: the close button, which Wine delivers as a
// system command, a plain close message, or Alt+F4 as a key press.
static BOOL asks_to_close(const MSG *msg) {
  switch (msg->message) {
  case WM_SYSCOMMAND: return (msg->wParam & 0xfff0) == SC_CLOSE;
  case WM_CLOSE: return TRUE;
  case WM_SYSKEYDOWN: return msg->wParam == VK_F4 && (msg->lParam & (1 << 29));   // bit 29: Alt is down
  }
  return FALSE;
}

// Presses and releases a key, as the keyboard would.
static void tap(WORD key) {
  INPUT press = {INPUT_KEYBOARD}, release = {INPUT_KEYBOARD};
  press.ki.wVk = release.ki.wVk = key;
  press.ki.wScan = release.ki.wScan = (WORD)MapVirtualKeyW(key, MAPVK_VK_TO_VSC);
  release.ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(1, &press, sizeof(press));
  Sleep(80);
  SendInput(1, &release, sizeof(release));
}

// Leaves the game its own way. Escape steps back one screen, and during play it asks
// "Do you really want to quit?", which Y answers. Escape at the title screen quits.
// Alternating the two gets out from anywhere within a few rounds.
static DWORD WINAPI leave(void *unused) {
  SetForegroundWindow(game_window);
  for (int round = 0; round < 8; round++) {
    tap(VK_ESCAPE);
    Sleep(300);
    tap('Y');
    Sleep(300);
  }
  TerminateProcess(GetCurrentProcess(), 0);
  return 0;
}

// Runs inside the game, on its window's thread, for each message it takes.
static LRESULT CALLBACK on_message(int code, WPARAM wparam, LPARAM lparam) {
  static BOOL leaving;
  MSG *msg = (MSG *)lparam;
  HWND window = code == HC_ACTION && msg->hwnd ? GetAncestor(msg->hwnd, GA_ROOT) : NULL;
  if (window) {
    // Take "no close" off the window's class and ungrey Close in its menu. Wine checks both.
    DWORD style = GetClassLongW(window, GCL_STYLE);
    if (style & CS_NOCLOSE) SetClassLongW(window, GCL_STYLE, style & ~CS_NOCLOSE);
    HMENU menu = GetSystemMenu(window, FALSE);
    UINT state = menu ? GetMenuState(menu, SC_CLOSE, MF_BYCOMMAND) : (UINT)-1;
    if (state != (UINT)-1 && (state & (MF_GRAYED | MF_DISABLED)))
      EnableMenuItem(menu, SC_CLOSE, MF_BYCOMMAND | MF_ENABLED);

    if (asks_to_close(msg)) {
      // The engine's own answer to a close is a warning box, so the message stops here.
      msg->message = WM_NULL;
      if (!leaving) {
        leaving = TRUE;
        game_window = window;
        HANDLE thread = CreateThread(NULL, 0, leave, NULL, 0, NULL);
        if (thread) CloseHandle(thread);
        else TerminateProcess(GetCurrentProcess(), 0);
      }
    }
  }
  return CallNextHookEx(NULL, code, wparam, lparam);
}

__declspec(dllexport) HOOKPROC closer_hook(void) { return on_message; }

BOOL WINAPI _DllMainCRTStartup(HINSTANCE dll, DWORD reason, LPVOID reserved) { return TRUE; }

#else

static PROCESS_INFORMATION game;

// The game's command line is everything after our own name on ours.
static WCHAR *after_program_name(WCHAR *p) {
  BOOL quoted = FALSE;
  for (; *p && (quoted || (*p != ' ' && *p != '\t')); p++)
    if (*p == '"') quoted = !quoted;
  while (*p == ' ' || *p == '\t') p++;
  return p;
}

// Stops at the game's first visible window.
static BOOL CALLBACK find_window(HWND wnd, LPARAM found) {
  DWORD process;
  GetWindowThreadProcessId(wnd, &process);
  if (process != game.dwProcessId || !IsWindowVisible(wnd)) return TRUE;
  *(HWND *)found = wnd;
  return FALSE;
}

void closer_main(void) {
  // Closer.dll sits next to this program.
  WCHAR path[MAX_PATH];
  DWORD len = GetModuleFileNameW(NULL, path, MAX_PATH);
  if (len < 4 || len >= MAX_PATH) ExitProcess(2);
  lstrcpyW(path + len - 3, L"dll");
  HMODULE dll = LoadLibraryW(path);
  HOOKPROC (*hook_proc)(void) = dll ? (HOOKPROC (*)(void))GetProcAddress(dll, "closer_hook") : NULL;

  // The game shows its window the way it is told to at start-up, so say so.
  STARTUPINFOW start = {sizeof(start)};
  start.dwFlags = STARTF_USESHOWWINDOW;
  start.wShowWindow = SW_SHOWNORMAL;
  if (!CreateProcessW(NULL, after_program_name(GetCommandLineW()), NULL, NULL, FALSE, 0, NULL, NULL, &start, &game))
    ExitProcess(3);

  // Wait for the game to end. Five times a second, make sure the hook is on the thread
  // that owns the game's window, and send that window an empty message so the hook
  // runs even while the game is idle.
  HHOOK hook = NULL;
  DWORD hooked = 0;
  while (MsgWaitForMultipleObjects(1, &game.hProcess, FALSE, 200, QS_ALLINPUT) != WAIT_OBJECT_0) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
    HWND window = NULL;
    EnumWindows(find_window, (LPARAM)&window);
    if (!window || !hook_proc) continue;
    DWORD thread = GetWindowThreadProcessId(window, NULL);
    if (thread != hooked) {
      if (hook) UnhookWindowsHookEx(hook);
      hook = SetWindowsHookExW(WH_GETMESSAGE, hook_proc(), dll, thread);
      hooked = hook ? thread : 0;
    }
    PostMessageW(window, WM_NULL, 0, 0);
  }
  DWORD code = 0;
  GetExitCodeProcess(game.hProcess, &code);
  ExitProcess(code);
}

#endif
