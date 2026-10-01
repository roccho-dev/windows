#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; Read-only and advisory: the six conventional Win32 UI fonts as this session uses them (SystemParametersInfoW GET:
; NONCLIENTMETRICSW caption, small caption, menu, status, message, and the icon title LOGFONTW) beside their persisted
; HKCU WindowMetrics values. win.ps1 writes only those persisted values (face only, through the registry), which take
; effect at the next sign-in; this tells pendingLogon from active. Nothing is ever set: SPI's SET calls recompute and
; persist the window geometry too. Run with the locked AutoHotkey interpreter (no compiler); no input, hooks or windows.
;   get   one JSON line: each slot's face, live LOGFONT and persisted value (hex). Exit 0, or 1 with the error on stderr.

Offsets := Map("caption", 24, "smCaption", 124, "menu", 224, "status", 316, "message", 408, "icon", 0)
Values := Map("caption", "CaptionFont", "smCaption", "SmCaptionFont", "menu", "MenuFont", "status", "StatusFont",
    "message", "MessageFont", "icon", "IconFont")
Order := ["caption", "smCaption", "menu", "status", "message", "icon"]
Metrics := "HKCU\Control Panel\Desktop\WindowMetrics"
OnError((failure, *) => Done(1, "", Describe(failure)))  ; never an error dialog: the caller has no window

try {
    if A_Args.Length = 1 && A_Args[1] == "get"
        Done(0, Json(Snapshot(Read())))
    Done(1, "", "usage: get")
} catch as failure {
    Done(1, "", Describe(failure))
}

; One line for the caller's stderr: the error, what raised it, and where.
Describe(failure) => !(failure is Error) ? "thrown: " String(failure)
    : failure.Message (failure.What != "" ? " (" failure.What ")" : "") " at " failure.File ":" failure.Line

Done(code, out, err := "") {
    if out != ""
        FileAppend(out "`n", "*", "UTF-8-RAW")
    if err != ""
        FileAppend(err "`n", "**", "UTF-8-RAW")
    ExitApp(code)
}

; The live structures: NONCLIENTMETRICSW of Windows Vista and later (504 bytes) and the icon title LOGFONTW (92).
Read() {
    ncm := Buffer(504, 0), icon := Buffer(92, 0)
    NumPut("UInt", 504, ncm, 0)
    if !DllCall("SystemParametersInfoW", "UInt", 0x29, "UInt", 504, "Ptr", ncm, "UInt", 0)  ; SPI_GETNONCLIENTMETRICS
        throw Error("SPI_GETNONCLIENTMETRICS failed (" A_LastError ")")
    if !DllCall("SystemParametersInfoW", "UInt", 0x1F, "UInt", 92, "Ptr", icon, "UInt", 0)  ; SPI_GETICONTITLELOGFONT
        throw Error("SPI_GETICONTITLELOGFONT failed (" A_LastError ")")
    return {ncm: ncm, icon: icon}
}

Hex(buffer, at, length) {
    text := ""
    loop length
        text .= Format("{:02X}", NumGet(buffer, at + A_Index - 1, "UChar"))
    return text
}

; lfFaceName is WCHAR[32] at byte 28 of the 92-byte LOGFONTW: hex characters 57 to 184.
FaceOf(logfontHex) {
    face := ""
    loop 32 {
        unit := Integer("0x" SubStr(logfontHex, 57 + (A_Index - 1) * 4 + 2, 2) SubStr(logfontHex, 57 + (A_Index - 1) * 4, 2))
        if !unit
            break
        face .= Chr(unit)
    }
    return face
}

; slot -> {face, live, persisted}.
Snapshot(live) {
    slots := Map()
    for slot in Order {
        buffer := slot == "icon" ? live.icon : live.ncm
        fontHex := Hex(buffer, Offsets[slot], 92)  ; not "hex": names ignore case, so a local hex would shadow Hex()
        persisted := ""
        try persisted := StrUpper(RegRead(Metrics, Values[slot]))
        slots[slot] := {face: FaceOf(fontHex), live: fontHex, persisted: persisted}
    }
    return {slots: slots}
}

; ASCII JSON: anything else as \uXXXX.
Quote(text) {
    out := '"'
    loop parse text {
        code := Ord(A_LoopField)
        out .= code = 34 ? '\"' : code = 92 ? "\\" : (code < 32 || code > 126) ? Format("\u{:04x}", code) : A_LoopField
    }
    return out '"'
}
Json(state) {
    parts := []
    for slot in Order {
        s := state.slots[slot]
        parts.Push(Quote(slot) ':{"face":' Quote(s.face) ',"live":' Quote(s.live) ',"persisted":' Quote(s.persisted) '}')
    }
    joined := ""
    for i, part in parts
        joined .= (i > 1 ? "," : "") part
    return '{"slots":{' joined '}}'
}
