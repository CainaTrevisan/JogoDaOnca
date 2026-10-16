#+feature dynamic-literals
package onca

main :: proc() {

    init_game()
    defer close_game()

    rl.PlayMusicStream(ui.assets.bgm)

    for !rl.WindowShouldClose() {
        @static frame: int
        frame += 1
        if frame % 30 == 0 do read_configs_noblocking()
        if .Mute_BGM not_in ui.flags do rl.UpdateMusicStream(ui.assets.bgm)

        adjacencies_and_captures: Adjacency
        update(&adjacencies_and_captures)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        if .Render_Rules in ui.flags {
            render_rules()
        } else {
            render_board(adjacencies_and_captures)
            render_pieces()
        }
    }
}

init_game :: proc() {
    build_topology()
    build_vert_grid()

    nbio.acquire_thread_event_loop()
    // read_configs_noblocking()

    ui.scale  = configs["scale"].(f32)
    ui.screen = { configs["screen_width"].(f32), configs["screen_height"].(f32) }
    ui.unit   = min(ui.screen.x * ui.scale/4, ui.screen.y * ui.scale/6)

    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT});
    rl.InitWindow(cast(i32) ui.screen.x, cast(i32) ui.screen.y, "Onça")

    rl.InitAudioDevice()

    // SFX
    load_sound_from_memory :: proc(sfx: ^rl.Sound, bytes: []u8) {
        wave := rl.LoadWaveFromMemory(".wav", rawptr(raw_data(bytes)), cast(i32) len(bytes))
        sfx^  = rl.LoadSoundFromWave(wave)
        rl.UnloadWave(wave)
    }
    load_sound_from_memory(&ui.assets.sfx_move,    move_bytes)
    load_sound_from_memory(&ui.assets.sfx_capture, capture_bytes)

    // BGM
    ui.assets.bgm = rl.LoadMusicStreamFromMemory(".wav", rawptr(raw_data(bgm_bytes)), cast(i32) len(bgm_bytes))

    // Font
    codepointCount: i32 = 0
    codepoints := rl.LoadCodepoints(
        " !\"#$%&'()*+,-./0123456789:;<=>?ABCDEFGHIJKLMNOPQRSTUVWXYZÃÇ[\\]^_`abcdefghijklmnopqrstuvwxyzçéáíó{|}~",
        &codepointCount
    )
    ui.assets.font = rl.LoadFontFromMemory(".ttf", rawptr(raw_data(font_bytes)), cast(i32) len(font_bytes), 64, codepoints, codepointCount)
    rl.UnloadCodepoints(codepoints)
}

close_game :: proc() {
    nbio.release_thread_event_loop()
    rl.CloseWindow()
    rl.CloseAudioDevice()

    rl.UnloadSound(ui.assets.sfx_move)
    rl.UnloadSound(ui.assets.sfx_capture)
    rl.UnloadMusicStream(ui.assets.bgm)
    rl.UnloadFont(ui.assets.font)
}

read_configs_noblocking :: proc() {
    if err := nbio.tick(timeout=0); err != nil {
        log.errorf("nbio.tick: %v", err)
    }
    config_file_buffer: string

    parse_config_file :: proc(_: rawptr, buf: []byte, err: nbio.Read_Entire_File_Error) {
        if err.value != nil {
            log.errorf("str(%q): %v: %v", CONFIG_PATH, err.operation, err.value)
            return
        }

        file := strings.trim(string(buf), " \n\t")

        for line in strings.split_lines(file) {
            config := strings.trim(line, " \n\t")
            if config == "" do continue
            pair     := strings.split(config, " ")
            key := slice.first(pair)
            keys :: []string {
                "scale",
                "screen_width",
                "screen_height",
                "border_size",
                "line_size",
                "vertex_size",
                "dog_size",
                "jaguar_size",
                "bg_color",
                "fg_color",
                "button_bg_color",
                "button_fg_color",
                "dog_color",
                "jaguar_color",
                "highlight_color",
                "turn_color",
                "last_move_color",
            }
            valid := false
            color := true if strings.contains(key, "color") else false
            for k in keys {
                if k == key {
                    valid = true
                }
            }
            if !valid {
                log.errorf("config invalid: %v", key)
                return
            }
            if color {
                number,_ := strconv.parse_int(slice.last(pair))
                configs[key] = cast(u32) number
            } else {
                number,_ := strconv.parse_f32(slice.last(pair))
                configs[key] = number
            }
        }
    }

    nbio.read_entire_file(CONFIG_PATH, &config_file_buffer, parse_config_file)
}

update :: proc (adjacencies_and_captures: ^Adjacency) {

    layout_ui()
    update_vertices()

    mouse = rl.GetMousePosition()

    button :: proc(id: UI_Kind, hover: UI_Flags) -> (clicked: bool) {
        if rl.CheckCollisionPointRec(mouse, rect_from_ui_elem(id)) {
            ui.flags  += {hover}
            clicked = rl.IsMouseButtonPressed(.LEFT)
        } else {
            ui.flags -= {hover}
        }
        return
    }

    if button(.Rules_Button,   .Button_Hover)  do ui.flags ~= {.Render_Rules}
    if button(.Restart_Button, .Restart_Hover) do ui.flags += {.Restart}

    if .Restart in ui.flags {
        drag_from        = -1
        last_jaguar_move = {}
        last_dog_move    = {}
        ui.flags         &= {.Mute_BGM}
        game             = INITIAL_GAME
    }

    if rl.IsKeyPressed(.M) {
        ui.flags ~= {.Mute_BGM}
    }

    adjacencies_and_captures^ = compute_possible_captures()
    if check_if_dogs_won(adjacencies_and_captures^) {
        ui.flags += {.Dogs_Won}
    }

    if game.chain {
        if adjacencies_and_captures[game.jaguar] - adjacencies[game.jaguar] == {} {
            game.turn = .Dogs
            game.chain = false
        }
    }

    game_over := game.score == 5 || .Dogs_Won in ui.flags

    if drag_from < 0 && rl.IsMouseButtonDown(.LEFT) {
        for piece, idx in game.board {
            hit := false
            collision_multiplier :: 2
            switch piece {
            case .Jaguar: hit = rl.CheckCollisionPointCircle(mouse, vertices[idx], ui.jaguar_size * collision_multiplier)
            case .Dog:    hit = rl.CheckCollisionPointRec(mouse, center_rect(vertices[idx], ui.dog_size * collision_multiplier * 1.5))
            case .None:
            }
            if hit { drag_from = idx; break }
        }
    }

    if rl.IsMouseButtonUp(.LEFT) {
        if !game_over && drag_from >= 0 {
            piece := game.board[drag_from]
            moves := adjacencies_and_captures[drag_from]
            if game.chain do moves -= adjacencies[drag_from]

            for to in moves {
                if game.board[to] != .None do continue
                moved := false
                collision_size := ui.vertex_size * 4
                switch {
                case piece == .Jaguar && game.turn == .Jaguar:
                    if rl.CheckCollisionCircles(mouse, ui.jaguar_size, vertices[to], collision_size) {
                        moved = true
                        if to in adjacencies[drag_from] {
                            game.turn = .Dogs
                        } else {                                   // a jump
                            over,_ := find_jump(drag_from, to)
                            game.board[over] = .None
                            game.score += 1
                            game.chain = true
                        }
                        last_jaguar_move = {drag_from, to}
                    }
                case piece == .Dog && game.turn == .Dogs:
                    if rl.CheckCollisionCircleRec(vertices[to], collision_size, center_rect(mouse, ui.dog_size)) {
                        moved = true
                        game.turn = .Jaguar
                        last_dog_move = {drag_from, to}
                    }
                }
                if moved {
                    game.board[drag_from], game.board[to] = .None, piece
                    if piece == .Jaguar do game.jaguar = to
                    rl.PlaySound(ui.assets.sfx_capture if game.chain else ui.assets.sfx_move)
                    break
                }
            }
        }
        drag_from = -1
    }
}

center_rect :: proc(pos: rl.Vector2, size: f32) -> rl.Rectangle {
    return {pos.x - size/2, pos.y - size/2, size, size}
}

compute_possible_captures :: proc() -> Adjacency {
    adjacencies_and_captures := adjacencies

    for j in JUMPS {
        if j.from             == game.jaguar &&
           game.board[j.over] == .Dog        &&
           game.board[j.to]   == .None {
                adjacencies_and_captures[game.jaguar] += {j.to}
        }
    }
    return adjacencies_and_captures
}

check_if_dogs_won :: proc(adjacencies_and_captures: Adjacency) -> bool {

    if game.turn == .Dogs do return false

    for vert in adjacencies_and_captures[game.jaguar] {
        if game.board[vert] == .None do return false
    }
    return true
}

render_board :: proc(adjacencies_and_captures: Adjacency) {
    bg_color,_        := configs["bg_color"].(u32)
    fg_color,_        := configs["fg_color"].(u32)
    last_move_color,_ := configs["last_move_color"].(u32)
    highlight_color,_ := configs["highlight_color"].(u32)
    jaguar_color,_    := configs["jaguar_color"].(u32)
    dog_color,_       := configs["dog_color"].(u32)
    turn_color,_      := configs["turn_color"].(u32)

    // Background
    rl.ClearBackground(rl.GetColor(bg_color))

    // Board Square
    rl.DrawRectangleRec(rect_from_ui_elem(.Square), rl.GetColor(fg_color))

    // Board Triangle
    t  := ui.elem[.Triangle]
    v1 := rl.Vector2{t.pos.x + t.size.x * 0.5, t.pos.y}
    v2 := rl.Vector2{t.pos.x, t.pos.y + t.size.y}
    v3 := t.pos + t.size
    rl.DrawTriangle(v1, v2, v3, rl.GetColor(fg_color))

    // Lines
    for i in 1 ..= 3 {
        rl.DrawLineEx(vertices[i],   vertices[20+i],  4, rl.GetColor(bg_color))
        rl.DrawLineEx(vertices[5*i], vertices[5*i+4], 4, rl.GetColor(bg_color))
    }

    // Diagonal Lines
    for v in ([?]int{6, 8, 16, 18}) {
        pos := vertices[v]
        start := pos - rl.Vector2{ui.unit, ui.unit}
        end   := pos + rl.Vector2{ui.unit, ui.unit}
        rl.DrawLineEx(start, end, 4, rl.GetColor(bg_color))

        start += rl.Vector2{2*ui.unit,0}
        end   -= rl.Vector2{2*ui.unit,0}
        rl.DrawLineEx(start, end, 4, rl.GetColor(bg_color))
    }

    // Triangle Lines
    rl.DrawLineEx(vertices[22], vertices[29], 4, rl.GetColor(bg_color))
    rl.DrawLineEx(vertices[25], vertices[27], 4, rl.GetColor(bg_color))

    // Score
    score_text := cstring(raw_data([]u8{game.score + '0', 0}))
    font_size := ui.unit * 0.45
    rl.DrawTextEx(ui.assets.font, score_text, ui.elem[.Score].pos, font_size, 0, rl.LIGHTGRAY);

    // Render Last Move
    render_last_move()

    highlight_from := drag_from
    if game.chain && game.score != 5 {
        highlight_from = game.jaguar
    }

    // Render vertices
    for v, idx in vertices {
        color := rl.WHITE
        last_move := last_jaguar_move if game.turn == .Dogs || game.chain else
                     last_dog_move

        if idx == last_move[0] {
            color = rl.GetColor(last_move_color)
        }
        if highlight_from >= 0 {
            possible_moves := adjacencies_and_captures[highlight_from]
            if game.chain {
                possible_moves -= adjacencies[highlight_from]
            }
            if idx in possible_moves {
                color = rl.GetColor(highlight_color)
            }
        }

        rl.DrawCircleV(v, ui.vertex_size, color)
        render_highlight_around_circle(
            v,
            ui.vertex_size,
            ui.line_size,
            rl.GetColor(bg_color)
        )
    }

    render_status()
    render_button(.Rules_Button,   "Regras",    ui.line_size, .Button_Hover  in ui.flags)
    render_button(.Restart_Button, "Reiniciar", ui.line_size, .Restart_Hover in ui.flags)
}

render_button :: proc(id: UI_Kind, label: cstring, thickness: f32, hover: bool) {
    rect   := rect_from_ui_elem(id)
    color1 := rl.GetColor(configs["button_fg_color"].(u32))
    color2 := rl.GetColor(configs["button_bg_color"].(u32))
    if hover do color1, color2 = color2, color1
    rl.DrawRectangleRec(rect, color1)
    render_highlight_around_rect(rect, thickness, rl.GetColor(configs["fg_color"].(u32)))

    font_size: f32 = ui.unit * 0.19
    text_size := rl.MeasureTextEx(ui.assets.font, label, font_size, 0)
    w := rect.x + rect.width  * 0.5 - text_size.x * 0.5
    h := rect.y + rect.height * 0.5 - font_size   * 0.5
    rl.DrawTextEx(ui.assets.font, label, rl.Vector2{w, h}, font_size, 0, color2);
}

render_highlight_around_rect :: proc(rect: rl.Rectangle, thickness: f32, color: rl.Color) {
    rect := rect
    rect.x -= thickness
    rect.y -= thickness
    rect.width += thickness * 2
    rect.height += thickness * 2
    rl.DrawRectangleLinesEx(rect, thickness, color)
}

render_highlight_around_circle :: proc (center: rl.Vector2, size: f32, thickness: f32, color: rl.Color) {
    rl.DrawRing(center, size, size + thickness, 0, 360, 0, color)
}

render_pieces :: proc() {
    jaguar_color,_    := configs["jaguar_color"].(u32)
    dog_color,_       := configs["dog_color"].(u32)
    highlight_color,_ := configs["highlight_color"].(u32)
    turn_color,_      := configs["turn_color"].(u32)

    LERP :: 0.8

    for piece, idx in game.board {
        if piece == .None do continue
        hl_color := rl.Color{0,0,0,255}
        if piece == .Dog {
            rect  := center_rect(vertices[idx], ui.dog_size)
            color := rl.GetColor(dog_color)
            if idx == drag_from {
                color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
            }
            rl.DrawRectangleRec(rect, color)
            if game.turn == .Dogs {
                hl_color = rl.GetColor(turn_color)
            }
            render_highlight_around_rect(rect, ui.line_size, hl_color)

        } else if piece == .Jaguar {
            color := rl.GetColor(jaguar_color)
            if idx == drag_from {
                color = rl.ColorLerp(color, rl.Color{0, 0, 0, 255}, LERP)
            }
            rl.DrawCircleV(vertices[idx], ui.jaguar_size, color)
            if game.turn == .Jaguar {
                hl_color = rl.GetColor(turn_color)
            }
            render_highlight_around_circle(
                vertices[idx],
                ui.jaguar_size,
                ui.line_size,
                hl_color
            )
        }
    }

    if drag_from < 0 do return

    if game.board[drag_from] == .Dog {
        rect := center_rect(mouse, ui.dog_size)
        rl.DrawRectangleRec(rect, rl.GetColor(dog_color))
        render_highlight_around_rect(rect, ui.line_size, rl.GetColor(highlight_color))

    } else if game.board[drag_from] == .Jaguar {
        rl.DrawCircleV(mouse, ui.jaguar_size, rl.GetColor(jaguar_color))
        render_highlight_around_circle(
            mouse,
            ui.jaguar_size,
            ui.line_size,
            rl.GetColor(highlight_color)
        )
    }
}

render_last_move :: proc() {

    last_move := last_jaguar_move if game.turn == .Dogs || game.chain else
                 last_dog_move

    is_jaguar_move := game.turn == .Dogs || game.chain

    border,_ := configs["border_size"].(f32)

    start := vertices[last_move[0]]
    end   := vertices[last_move[1]]

    color,_ := configs["last_move_color"].(u32)
    if over, ok := find_jump(last_move[0], last_move[1]); ok {
        rl.DrawLineEx(start, vertices[over], 4, rl.GetColor(color))
        rl.DrawLineEx(end,   vertices[over], 4, rl.GetColor(color))
    } else {
        rl.DrawLineEx(start, end, 4, rl.GetColor(color))
    }

    rl.DrawCircleV(start, ui.vertex_size, rl.GetColor(color))
    if is_jaguar_move {
        rl.DrawRing(end, ui.jaguar_size, ui.jaguar_size + border * 1.2,
        0, 360, 0, rl.GetColor(color))
    } else if last_dog_move != {0, 0} {
        rect := rl.Rectangle {
            end.x - ui.dog_size/2 - border,
            end.y - ui.dog_size/2 - border,
            ui.dog_size + border* 2, ui.dog_size + border* 2,
        }
        rl.DrawRectangleLinesEx(rect, border * 1.3, rl.GetColor(color))
    }
}

render_rules :: proc() {
    rl.ClearBackground(rl.GetColor(configs["bg_color"].(u32)))

    rules_text := []cstring {
    "2 jogadores jogam em turnos: ",
    "",
    "um com a Onça:",
    "",
    "o outro com os Cachorros:",
    "",
    "Em seu turno, mova uma peça para um",
    "vértice vizinho pelas linhas do",
    "tabuleiro: vertical, horizontal ou",
    "diagonal.",
    "",
    "",
    "A Onça também pode saltar sobre um",
    "cachorro, capturando-o, se a casa",
    "logo atrás dele estiver vazia. Após",
    "capturar, deve continuar saltando",
    "enquanto houver capturas possíveis.",
    "",
    "",
    "Onça vence ao capturar 5 Cachorros.",
    "Cachorros vencem se encurralarem a",
    "Onça (sem movimentos possíveis).",
    }

    font_size: f32 = ui.unit * 0.3
    origin := ui.elem[.Rules_Text].pos
    w, h   := origin.x, origin.y

    for line, idx in rules_text {
        switch idx {
        case 1:
            color,_       := configs["jaguar_color"].(u32)
            padding := 0.2 * ui.unit
            mesg_size := rl.MeasureTextEx(ui.assets.font, "um com a Onça:", font_size, 0)
            pos := rl.Vector2 {
                w + mesg_size.x + ui.jaguar_size + padding,
                h + mesg_size.y + ui.jaguar_size * 0.5
            }
            rl.DrawCircleV(pos, ui.jaguar_size, rl.GetColor(color))
            render_highlight_around_circle(
                pos,
                ui.jaguar_size,
                ui.line_size,
                rl.GetColor(configs["turn_color"].(u32)),
            )

        case 3:
            color,_    := configs["dog_color"].(u32)
            padding := 0.15 * ui.unit
            mesg_size := rl.MeasureTextEx(ui.assets.font, "o outro com os Cachorros", font_size, 0)
            rect := rl.Rectangle {
                w + mesg_size.x + ui.dog_size + padding,
                h + mesg_size.y,
                ui.dog_size,
                ui.dog_size,
            }
            rl.DrawRectangleRec(rect, rl.GetColor(color))
            render_highlight_around_rect(rect, ui.line_size, rl.GetColor(configs["turn_color"].(u32)))
        }
        rl.DrawTextEx(ui.assets.font, line, rl.Vector2{w, h}, font_size, 1, rl.RAYWHITE)
        h += font_size * 0.75
    }

    render_button(.Rules_Button, "Voltar", ui.line_size, .Button_Hover in ui.flags)
}


render_status :: proc () {
    mesg1, mesg2: cstring = "ONÇA ", "JOGA"
    color  := rl.GetColor(configs["jaguar_color"].(u32))
    color2 := rl.GetColor(configs["turn_color"].(u32))
    if game.score == 5 {
        mesg1, mesg2 = "ONÇA ", "GANHOU"
        color2 = color
    } else if .Dogs_Won in ui.flags {
        mesg1, mesg2 = "CACHORROS ", "GANHARAM"
        color  = rl.GetColor(configs["dog_color"].(u32))
        color2 = color
    } else if game.turn == .Dogs {
        mesg1, mesg2 = "CACHORROS ", "JOGAM"
        color = rl.GetColor(configs["dog_color"].(u32))
    }

    pos := ui.elem[.Turn_Mesg].pos
    font_size := ui.unit * 0.2
    mesg1_size := rl.MeasureTextEx(ui.assets.font, mesg1, font_size, 0)
    mesg2_size := rl.MeasureTextEx(ui.assets.font, mesg2, font_size, 0)
    pos.x -= (mesg1_size.x + mesg2_size.x) * 0.5
    rl.DrawTextEx(ui.assets.font, mesg1, pos, font_size, 0, color)
    rl.DrawTextEx(ui.assets.font, mesg2, pos + {mesg1_size.x, 0}, font_size, 0, color2)
}

build_topology :: proc() {
    link :: proc(a, b: int) {
        adjacencies[a] += {b}
        adjacencies[b] += {a}
    }
    add_jump :: proc(from, over, to: int) {
        append(&JUMPS, Jump{from, over, to}, Jump{to, over, from})
    }

    for line in LINES {
        for i in 0 ..< len(line)-1 do link(line[i], line[i+1])
        for i in 0 ..< len(line)-2 do add_jump(line[i], line[i+1], line[i+2])
    }
    for j in BENT_JUMPS do add_jump(j.from, j.over, j.to)
}

find_jump :: proc(from, to: int) -> (over: int, ok: bool) {
    for j in JUMPS {
        if j.from == from && j.to == to do return j.over, true
    }
    return -1, false
}

// Config
CONFIG_PATH :: "onca.cfg"

configs := map[string] union{f32, u32} {
    "scale"            = f32(90),
    "screen_width"     = f32(800),
    "screen_height"    = f32(1000),

    "border_size"      = f32(8),
    "line_size"        = f32(4),
    "vertex_size"      = f32(0.06),
    "dog_size"         = f32(0.18),
    "jaguar_size"      = f32(0.18),

    "bg_color"         = u32(0x120702ff),
    "fg_color"         = u32(0xd8a71eff),
    "button_bg_color"  = u32(0x160802ff),
    "button_fg_color"  = u32(0xd8a71eff),
    "dog_color"        = u32(0x473d2fff),
    "jaguar_color"     = u32(0xf2cf46ff),
    "highlight_color"  = u32(0x0fa0b0ff),
    "turn_color"       = u32(0x953218ff),
    "last_move_color"  = u32(0x10aa10ff),
}

// UI
UI_Kind :: enum {
    Screen,
    Turn_Mesg,
    Board,
    Square,
    Triangle,
    Score,
    Win_Mesg,
    Rules_Text,
    Rules_Button,
    Restart_Button,
}

UI_Elem :: struct {
    parent: UI_Kind,
    offset: rl.Vector2,
    pos:    rl.Vector2,
    size:   rl.Vector2,
}

UI_Flags :: enum {
    Button_Hover,
    Render_Rules,
    Restart_Hover,
    Restart,
    Dogs_Won,
    Mute_BGM,
}

Assets :: struct {
    sfx_move:    rl.Sound,
    sfx_capture: rl.Sound,
    bgm:         rl.Music,
    font:        rl.Font,
}

move_bytes    :: #load("move.wav")
capture_bytes :: #load("capture.wav")
bgm_bytes     :: #load("bgm.wav")
font_bytes    :: #load("Black Animal.ttf")

ui: struct {
    scale:       f32,
    unit:        f32,
    screen:      rl.Vector2,
    vertex_size: f32,
    jaguar_size: f32,
    dog_size:    f32,
    line_size:   f32,
    flags:       bit_set[UI_Flags],
    elem:        [UI_Kind]UI_Elem,
    using assets: Assets,
}

// INPUT
mouse: rl.Vector2
drag_from        := -1
last_jaguar_move := [2]int{}
last_dog_move    := [2]int{}

// Rules
NUM_VERTS :: 31

Piece :: enum u8 {None, Dog, Jaguar}

Jump :: struct { from, over, to: int }

LINES := [?][]int {
    // rows
    {0, 1, 2, 3, 4}, {5, 6, 7, 8, 9}, {10, 11, 12, 13, 14}, {15, 16, 17, 18, 19}, {20, 21, 22, 23, 24},
    // columns (the middle one runs through the triangle)
    {0, 5, 10, 15, 20}, {1, 6, 11, 16, 21}, {2, 7, 12, 17, 22, 26, 29}, {3, 8, 13, 18, 23}, {4, 9, 14, 19, 24},
    // square diagonals
    {0, 6, 12, 18, 24}, {4, 8, 12, 16, 20}, {2, 6, 10}, {2, 8, 14}, {10, 16, 22}, {14, 18, 22},
    // triangle edges
    {22, 25, 28}, {22, 27, 30}, {25, 26, 27}, {28, 29, 30},
}

BENT_JUMPS :: [?]Jump { {16, 22, 27}, {18, 22, 25} }
JUMPS: [dynamic; 96]Jump

Adjacency :: [31]bit_set[0..<31]
adjacencies: Adjacency

Side :: enum {Jaguar, Dogs}

Game :: struct {
    board: [NUM_VERTS]Piece,
    jaguar: int,
    score:  u8,
    turn:   Side,
    chain:  bool,
}

INITIAL_GAME :: Game {
    board = {
        00 ..< 12        = .Dog,
        12               = .Jaguar,
        13 ..< 15        = .Dog,
        15 ..< NUM_VERTS = .None,
    },
    jaguar = 12,
}
game := INITIAL_GAME

build_vert_grid :: proc() {
    n := 0
    for row in 0..<5 {
        for col in 0..<5 {
            vert_grid[n] = {f32(col), f32(row)}
            n += 1
        }
    }
    for i in 0..<3 { vert_grid[n] = {1.5 + f32(i)*0.5, 5}; n += 1 }   // 25..27
    for i in 0..<3 { vert_grid[n] = {1.0 + f32(i),     6}; n += 1 }
}

update_vertices :: proc() {
    pos := ui.elem[.Board].pos
    for row, idx in vert_grid do vertices[idx] = pos + row * ui.unit
}

layout_ui :: proc() {
    ui.screen = rl.Vector2{
        cast(f32) rl.GetScreenWidth(),
        cast(f32) rl.GetScreenHeight(),
    }
    ui.scale = configs["scale"].(f32) * 0.01
    ui.unit = min(ui.screen.x * ui.scale / 4, ui.screen.y * ui.scale / 6)
    u := ui.unit

    ui.vertex_size = configs["vertex_size"].(f32) * u
    ui.jaguar_size = configs["jaguar_size"].(f32) * u
    ui.dog_size    = configs["dog_size"].(f32) * u
    ui.line_size   = configs["line_size"].(f32)

    board_size := rl.Vector2{4*u, 6*u}

    ui.elem[.Screen]     = {parent = .Screen,     size = ui.screen                                          }
    ui.elem[.Turn_Mesg]  = {parent = .Screen,                         offset = {ui.screen.x * 0.5, u*0.1}   }
    ui.elem[.Board]      = {parent = .Turn_Mesg,  size = board_size,  offset = {-board_size.x * 0.5, u*0.4} }
    ui.elem[.Triangle]   = {parent = .Board,      size = {2*u, 2*u},  offset = {u, 4*u}                     }
    ui.elem[.Square]     = {parent = .Board,      size = {4*u, 4*u}                                         }
    ui.elem[.Score]      = {parent = .Board,                          offset = {0, -u*0.52}                 }
    ui.elem[.Win_Mesg]   = {parent = .Turn_Mesg,                                                            }
    ui.elem[.Rules_Text] = {parent = .Board,                                                                }

    w := 0.5 * u
    h := 0.4 * u
    y := 6 * u - (u - h) * 0.71
    ui.elem[.Rules_Button]   = {parent = .Board, size = {w, h}, offset = {3*u + (u - w) * 0.5, y} }
    ui.elem[.Restart_Button] = {parent = .Board, size = {w + u*0.1, h}, offset = {(u - w) * 0.5, y} }

    for &e in ui.elem do e.pos = e.offset + ui.elem[e.parent].pos
}

vertices:  [NUM_VERTS]rl.Vector2
vert_grid: [NUM_VERTS]rl.Vector2

rect_from_ui_elem :: proc(kind: UI_Kind) -> rl.Rectangle {
    e := ui.elem[kind]
    return rl.Rectangle{e.pos.x, e.pos.y, e.size.x, e.size.y}
}

/*

AI:
legal_moves :: proc(g: Game) -> []Jumps
apply_move  :: proc(g: ^Game, j: Jump)
evaluate_position :: proc(g: Game) -> (evaluation: int)

*/

import "core:fmt"
import "core:nbio"
import "core:log"
import "core:strings"
import "core:slice"
import "core:strconv"
import rl "vendor:raylib"

/*
@TODO
[ ] Better Colors
[ ] read file before initializing window
[ ] reorder code

@FEATURES
[ ] Implement images for the rules
[ ] Mute button
[ ] Volume control
[ ] Implement Skip button after captures ???
[ ] Change highlight color for piece that could be captured on a possible move
[ ] animation for piece capture @VISUAL
[ ] implement networking
[ ] implement computer AI

@BUGS:

@REFACTOR:
[ ] all configs in ui
[ ] rules button parent should be restart button
[ ] retain board square state for rendering
[ ] collapse data into game_state and input structs
[ ] render_highlight_around does not seem useful
[ ] recompute rects, triangles, and lines for rendering the board only on resize
*/
