#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; The six conventional Win32 UI font slots, face only, through the documented SystemParametersInfoW:
; NONCLIENTMETRICSW (caption, small caption, menu, status, message) and the icon title LOGFONTW. Run by
; win.ps1 with the locked AutoHotkey interpreter (no compiler); no input, hooks, windows or other settings.
;   get                                  one JSON line: each slot's face, live LOGFONT and persisted value (hex)
;   set <face> <slot>=<expected face>... each named slot must have its expected face now; only lfFaceName changes
; set refuses (exit 2, nothing written) unless every slot's persisted HKCU WindowMetrics value equals its live
; LOGFONT, so writing the live structure back cannot move a size or weight. Afterwards every slot, every other
; WindowMetrics value and every LOGFONT byte but the named faces must be unchanged; otherwise the live structures
; and the persisted values are put back (exit 3). Exit 0: done, the new state on stdout; 1: any other failure.

Offsets := Map("caption", 24, "smCaption", 124, "menu", 224, "status", 316, "message", 408, "icon", 0)
Values := Map("caption", "CaptionFont", "smCaption", "SmCaptionFont", "menu", "MenuFont", "status", "StatusFont",
    "message", "MessageFont", "icon", "IconFont")
Order := ["caption", "smCaption", "menu", "status", "message", "icon"]
Metrics := "HKCU\Control Panel\Desktop\WindowMetrics"
OnError((failure, *) => Done(1, "", failure.Message))  ; never an error dialog: the caller has no window

try {
    if A_Args.Length = 1 && A_Args[1] == "get"
        Done(0, Json(Snapshot(Read())))
    if A_Args.Length >= 3 && A_Args[1] == "set"
        SetFaces(A_Args[2])
    Done(1, "", "usage: get | set <face> <slot>=<expected face>...")
} catch as failure {
    Done(1, "", failure.Message)
}

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

; SPIF_UPDATEINIFILE | SPIF_SENDCHANGE: persisted to HKCU WindowMetrics and announced to open windows.
Write(live, ncm, icon) {
    if ncm && !DllCall("SystemParametersInfoW", "UInt", 0x2A, "UInt", 504, "Ptr", live.ncm, "UInt", 3)  ; SPI_SETNONCLIENTMETRICS
        throw Error("SPI_SETNONCLIENTMETRICS failed (" A_LastError ")")
    if icon && !DllCall("SystemParametersInfoW", "UInt", 0x22, "UInt", 92, "Ptr", live.icon, "UInt", 3)  ; SPI_SETICONTITLELOGFONT
        throw Error("SPI_SETICONTITLELOGFONT failed (" A_LastError ")")
}

Hex(buffer, at, length) {
    text := ""
    loop length
        text .= Format("{:02X}", NumGet(buffer, at + A_Index - 1, "UChar"))
    return text
}

; lfFaceName is WCHAR[32] at byte 28 of the 92-byte LOGFONTW: hex characters 57 to 184.
FaceOf(hex) {
    face := ""
    loop 32 {
        unit := Integer("0x" SubStr(hex, 57 + (A_Index - 1) * 4 + 2, 2) SubStr(hex, 57 + (A_Index - 1) * 4, 2))
        if !unit
            break
        face .= Chr(unit)
    }
    return face
}
Rest(hex) => SubStr(hex, 1, 56) SubStr(hex, 185)

PutFace(live, slot, face) {
    buffer := slot == "icon" ? live.icon : live.ncm, at := Offsets[slot] + 28
    loop 32
        NumPut("UShort", 0, buffer, at + (A_Index - 1) * 2)
    loop parse face
        NumPut("UShort", Ord(A_LoopField), buffer, at + (A_Index - 1) * 2)
}

; slot -> {face, live, persisted}, plus every other WindowMetrics value (name -> type:data).
Snapshot(live) {
    slots := Map(), others := Map()
    for slot in Order {
        buffer := slot == "icon" ? live.icon : live.ncm
        hex := Hex(buffer, Offsets[slot], 92)
        persisted := ""
        try persisted := StrUpper(RegRead(Metrics, Values[slot]))
        slots[slot] := {face: FaceOf(hex), live: hex, persisted: persisted}
    }
    loop reg, Metrics, "V" {
        if !IsFontValue(A_LoopRegName)
            others[A_LoopRegName] := A_LoopRegType ":" RegRead()
    }
    return {slots: slots, others: others}
}
IsFontValue(name) {
    for slot, value in Values
        if value = name
            return true
    return false
}

SetFaces(face) {
    ; lfFaceName holds 31 UTF-16 units and a terminator; no controls, no surrogates.
    valid := StrLen(face) >= 1 && StrLen(face) <= 31
    loop parse face {
        code := Ord(A_LoopField)
        if code < 32 || code = 127 || code > 0xD7FF && code < 0xE000 || code > 0xFFFF
            valid := false
    }
    if !valid
        throw Error("Invalid face name: " face)
    expected := Map()
    loop A_Args.Length - 2 {
        pair := A_Args[A_Index + 2]
        if !RegExMatch(pair, "^(\w+)=(.+)$", &part) || !Offsets.Has(part[1]) || expected.Has(part[1])
            throw Error("Invalid slot argument: " pair)
        expected[part[1]] := part[2]
    }
    before := Read(), was := Snapshot(before)
    for slot in Order {
        if was.slots[slot].persisted == "" || Rest(was.slots[slot].persisted) != Rest(was.slots[slot].live)
            || FaceOf(was.slots[slot].persisted) !== was.slots[slot].face
            Done(2, "", "HKCU WindowMetrics " Values[slot] " does not match the live " slot " font; nothing written")
    }
    for slot, face0 in expected
        if was.slots[slot].face !== face0
            Done(2, "", slot " face is '" was.slots[slot].face "', not the expected '" face0 "'; nothing written")
    live := Read(), ncm := false, icon := false
    for slot in expected {
        PutFace(live, slot, face)
        if slot == "icon"
            icon := true
        else
            ncm := true
    }
    Write(live, ncm, icon)
    now := Snapshot(Read())
    problem := Differs(was, now, expected, face)
    if problem != "" {
        Write(before, ncm, icon)
        for slot in Order
            RegWrite(was.slots[slot].persisted, "REG_BINARY", Metrics, Values[slot])
        for name, typed in was.others {
            split := InStr(typed, ":")
            RegWrite(SubStr(typed, split + 1), SubStr(typed, 1, split - 1), Metrics, name)
        }
        for name in now.others
            if !was.others.Has(name)
                RegDelete(Metrics, name)
        Done(3, "", "verification failed, restored: " problem)
    }
    Done(0, Json(now))
}

Differs(was, now, expected, face) {
    for slot in Order {
        want := expected.Has(slot) ? face : was.slots[slot].face
        state := now.slots[slot]
        if state.face !== want || FaceOf(state.persisted) !== want
            return slot " face is '" state.face "' (persisted '" FaceOf(state.persisted) "'), not '" want "'"
        if Rest(state.live) != Rest(was.slots[slot].live) || Rest(state.persisted) != Rest(was.slots[slot].persisted)
            return slot " changed beyond its face"
    }
    for name, typed in was.others
        if !now.others.Has(name) || now.others[name] != typed
            return "WindowMetrics " name " changed"
    for name in now.others
        if !was.others.Has(name)
            return "WindowMetrics " name " appeared"
    return ""
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
