# VibeBuddy บน Waveshare ESP32-S3-RLCD-4.2

กล่องแจ้งสถานะ AI coding agent บนจอ RLCD ขาวดำ 400×300 — firmware รับ
**VibeBuddy Protocol v1** ผ่าน USB แล้ววาดการ์ดงาน 3 ใบ/หน้า, ส่วนฝั่ง Windows
มี **bridge** (PowerShell) รับ event จาก **OpenCode plugin** แล้วส่งต่อลงบอร์ด

```
OpenCode ──plugin──> bridge (127.0.0.1:7331) ──USB NDJSON──> ESP32-S3 ──> จอ RLCD
```

สถานะ: **MVP ใช้งานได้** (Step 1–4) — ยังไม่มีเสียง ปุ่ม Pomodoro/Leisure

ยืนยันบนฮาร์ดแวร์แล้ว: การ์ด 3 ใบ + NEED YOU กะพริบ, READY + stats, NO LINK,
`permission.asked` จาก OpenCode จริง → NEED YOU, และการส่ง event ที่มี task เดียว
(หลังแก้บั๊ก array) — หน้า DONE/FAILED ส่ง event ถูกต้องแล้ว

---

## ฮาร์ดแวร์

| รายการ | ค่า |
|---|---|
| บอร์ด | Waveshare/SpotPear ESP32-S3-RLCD-4.2 (N16R8) |
| จอ | ST7305 400×300 1-bit reflective, SPI: MOSI 12 / SCLK 11 / DC 5 / CS 40 / RST 41 |
| I2C | SDA 13 / SCL 14 (ES8311 0x18, ES7210 0x40, SHTC3 0x70, PCF85063 0x51) |
| I2S | MCLK 16 / BCLK 9 / WS 45 / DOUT 8 / DIN 10 |
| PA (amp enable) | GPIO46 (ยังไม่ใช้ — ยังไม่มีเสียง) |
| USB | native USB Serial/JTAG, `VID 303A:1001`, COM5 |

Backup firmware เดิม (นาฬิกา VolosR) อยู่ที่ `backup/clock-original-merged.bin`

---

## โครงไฟล์

```
vibe-buddy/
├─ vibe-buddy.ino         firmware: boot banner, serial reader, state machine
├─ ui.h / ui.cpp          หน้าจอ 400×300 (การ์ด, READY, NO LINK)
├─ vb_protocol.h/.cpp     ตัวอ่าน NDJSON ขนาดเล็ก (ไม่ใช้ library)
├─ display_bsp.h/.cpp     ไดรเวอร์ ST7305 (จาก Waveshare)
├─ inter24.h / inter15.h  ฟอนต์ Inter Bold (generate จาก tools/fontgen.py)
├─ fonts/                 สัญญาอนุญาต OFL ของฟอนต์
├─ opencode-plugin/       plugin ของ OpenCode (POST มาที่ bridge)
├─ tools/bridge.ps1       bridge: HTTP + serial + state
├─ tools/fontgen.py       TTF → GFX header + PNG preview
├─ tools/fake-daemon.ps1  ยิง event ทดสอบโดยไม่ต้องมี daemon
└─ backup/                merged.bin ของ firmware เดิม (ไม่ขึ้น git)
```

## ฟอนต์

ใช้ **Inter Bold** — ฟอนต์ sans แบบ vector ภายใต้ SIL OFL
(`fonts/INTER-OFL.txt`, https://github.com/rsms/inter)

- ชื่อการ์ด / สถานะ / เวลา: **24 px** (Bold)
- บรรทัดรอง: **15 px** (Bold)
- คำใหญ่ READY/DONE/FAILED: ฟอนต์ built-in 5×7 ขยาย
- สร้างใหม่/เปลี่ยนขนาด/เปลี่ยนฟอนต์ได้ด้วย `tools/fontgen.py` (ต้องมี Python + PIL)
  แล้วดู preview PNG ก่อนแฟลช: `python tools/fontgen.py <ttf> <name> --size 24 --small-size 15 --preview out.png`

---

## Build / Flash

ใช้ Arduino IDE ที่ติดตั้งอยู่ (bundled CLI):

```powershell
$cli = "$env:LOCALAPPDATA\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe"
$fqbn = "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi"

& $cli compile --fqbn $fqbn "D:\code\vibe-buddy"
& $cli upload  --fqbn $fqbn --port COM5 "D:\code\vibe-buddy"
```

ต้องตั้งค่าให้ตรง: **CDC On Boot = Enabled, Flash 16MB, PSRAM = OPI**
(ถ้าไม่ตรง จอจะไม่ขึ้น/แรมไม่พอสำหรับ LUT ของไดรเวอร์)

> ก่อน flash ให้ปิด bridge ก่อน เพราะ bridge ถือ COM5 อยู่

---

## ใช้งาน

1. เสียบสาย USB เข้าบอร์ด
2. เปิด bridge (ค้างไว้):

```powershell
powershell -ExecutionPolicy Bypass -File D:\code\vibe-buddy\tools\bridge.ps1
```

3. ตรวจว่าต่อติด:

```powershell
Invoke-RestMethod http://127.0.0.1:7331/v1/status
```

4. ใช้งาน OpenCode ตามปกติ → การ์ดจะขึ้นเอง (ไม่ต้อง restart ถ้า plugin โหลดอยู่)

หยุด: ปิดหน้าต่าง PowerShell หรือ `Stop-Process` ตาม PID ของ `bridge.ps1`
ถ้า bridge หยุด จอจะขึ้น `NO LINK` ภายใน 15 วินาที

### ทดสอบโดยไม่ใช้ OpenCode

```powershell
powershell -ExecutionPolicy Bypass -File tools\fake-daemon.ps1 -Mode demo
```

หรือยิงเข้า HTTP ตรง ๆ:

```powershell
$b = @{ agent="opencode"; session_id="ses_x"; event="working"; cwd="D:\code\vibe-buddy" } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Post http://127.0.0.1:7331/v1/agent-hooks -ContentType application/json -Body $b
```

`event`: `working` | `needs_input` | `done` | `stopped` | `session_end`

`needs_input` ถูกส่งอัตโนมัติเมื่อ OpenCode ขออนุญาต (`permission.asked`) — จอจะกะพริบ
`NEED YOU` จนกว่าจะตอบ

---

## OpenCode plugin

`~/.config/opencode/opencode.jsonc` ชี้มาที่ plugin ของโปรเจกต์นี้แล้ว:

```jsonc
{ "plugins": ["file:///D:/code/vibe-buddy/opencode-plugin"] }
```

ไฟล์เดิม (esp-buddy สำหรับ firmware avatar) ถูกสำรองไว้ที่
`opencode.jsonc.bak-bridge-20261108` — คัดลอกกลับได้ทุกเมื่อ

plugin เป็น fire-and-forget: ถ้า bridge ไม่ได้รันก็ไม่มีผลกับ OpenCode

---

## Protocol ที่ firmware รองรับ

ฝั่ง host → บอร์ด (NDJSON, บรรทัดละ object, รับ CRLF ด้วย):

```json
{"version":1,"event":"task.start","title":"...","tasks":[{"id":"a1","agent":"opencode","title":"...","project":"...","status":"working","elapsed_s":75}],"tasks_total":1,"stats":["3 DONE","1 ASK","1H20 BUSY"]}
```

- `task.start` / `agent.input_required` / `task.done` / `task.error` / `agent.blocked`
- `agent.idle` → หน้า READY + stats
- `device.hello` → บอร์ดตอบ banner (`DISPLAY READY BUILD …`, `FIRMWARE VERSION …`, `MODE`, `VOLUME`, `TOUCH NONE`)
- `device.heartbeat` → ใช้ `hour` แสดงนาฬิกาบนหัวจอตอนว่าง
- `tasks[]` สูงสุด 6 (จอแสดง 3 + `+N MORE`), `elapsed_s` นับต่อเองใน firmware
- ไม่ประกาศ `TRANSFER 1` → รับบรรทัดสูงสุด ~2 KB (buffer 2048)
- event ที่ไม่รู้จักจะถูกเมิน (forward compatible)

---

## บทเรียนจากการ bring-up (สำคัญถ้าจะแก้ต่อ)

1. **ฟอนต์พิกเซลต้อง pad ทุกแถวเป็น byte** — `Adafruit_GFX::print()` อ่าน bitmap
   แบบต่อเนื่องข้ามแถว จึงใช้ได้เฉพาะฟอนต์ที่ไม่ pad (เช่น Orbitron)
   → `ui.cpp` มี `draw_text()` เขียนเองแบบอ่านใหม่ทุกแถว (`ESP32-S3-AI` ทำแบบเดียวกัน)
2. **`setTextSize()` มีผลกับ custom font** ใน Adafruit GFX 1.12.6 — อักษรหลัง
   `READY` เดิมถูกขยาย 6 เท่าจนเป็น noise (ตอนนี้ไม่ใช้ print แล้ว)
3. **RX buffer ของ USB CDC default 256 bytes** — บรรทัดที่มี 5–6 การ์ดยาว ~1 KB
   ทำให้ bytes หล่นกลางบรรทัด ต้อง `Serial.setRxBufferSize(8192)` ก่อน `begin()`
4. `bitmapOffset` ของฟอนต์นี้เป็น byte offset ต่อแถว (`stride = (w+7)/8`)
5. จอเป็น 1-bit: `ColorWhite=0xFF` คือกระดาษ, ink คือเคลียร์บิต
6. **`ctx.location.directory` คือที่อยู่ของ plugin host ไม่ใช่ของ session** — บนเครื่องที่ใช้
   OpenCode service ตัวเดียว ทุก session จะถูกติดป้ายโปรเจกต์เดียวกัน (เจอจริง: การ์ดขึ้น
   `open-investing` ทั้งที่ทำงานใน `vibe-buddy`) ต้องใช้ `ev.location.directory` ของ event
   แต่ละตัว และให้ bridge อัปเดต cwd ของ session ที่มีอยู่แล้วได้

---

## ยังไม่มี / ข้อจำกัด

- ไม่มีเสียง (ES8311 + PA46 พร้อมใช้ แต่ยังไม่ implement)
- ไม่มีปุ่ม (K0=GPIO0, K1, K2 ยังไม่ผูก)
- ไม่มี Pomodoro / Leisure / touch / screenshot / OTA / voice command
- สถิติเป็นของ bridge (persist ที่ `%LOCALAPPDATA%\vibe-buddy-bridge\stats.json`)
- ข้อความทั้งหมดเป็นอังกฤษ (Poppins) — ยังไม่รองรับไทย เพราะเลี่ยงความเสี่ยงเรื่องฟอนต์
- ต้องรัน bridge ค้างไว้ (ติดตั้ง auto-start แล้ว ดูด้านล่าง)

### Auto-start

ติดตั้งแล้วผ่าน Startup folder (per-user, ไม่ต้อง admin):

```powershell
powershell -ExecutionPolicy Bypass -File tools\install-autostart.ps1
powershell -ExecutionPolicy Bypass -File tools\install-autostart.ps1 -Remove
```

ไฟล์ที่สร้าง: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\VibeBuddyBridge.vbs`
(Scheduled Task ใช้ไม่ได้บนเครื่องนี้ — ไม่มีสิทธิ์ admin ใน root folder)

---

## กู้คืน firmware เดิม (นาฬิกา)

```powershell
$esptool = "$env:LOCALAPPDATA\Arduino15\packages\esp32\tools\esptool_py\5.3.1\esptool.exe"
& $esptool --port COM5 write_flash 0x0 "D:\code\vibe-buddy\backup\clock-original-merged.bin"
```

---

## ต่อไป (ถ้าจะไปแผน A / ต่อยอด)

1. เสียง: ใช้ `codec_board` จาก `D:\code\ESP32-S3-AI` (ES8311 TDM, PA 46) เล่น chime/done/failed
2. ปุ่ม: K0/K1 สำหรับสลับหน้า/ปิดเสียง
3. ใช้ `vibebuddyd` ตัวจริงเมื่อมี Windows build — firmware นี้พูด protocol เดียวกันอยู่แล้ว
