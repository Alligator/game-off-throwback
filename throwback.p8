pico-8 cartridge // http://www.pico-8.com
version 14
__lua__
-- autocmd BufWritePost <buffer> silent make
PI = 3.14159
ROAD_HEIGHT = 58
INIT_TIMER = 60

SPR_ROAD = 0
SPR_FINISH = 8
SPR_0 = 224
SPR_MID_BG = 64

SFX_CHANNEL_CAR = 2
SFX_CHANNEL_MISC = 3

PICKUP_COLLECTED_TIMER = 60

CIG_FRAMES = {
    { sx = 64, sy = 0, width = 9, height = 16, offset = 0 },
    { sx = 73, sy = 0, width = 7, height = 16, offset = 1 },
    { sx = 78, sy = 0, width = 3, height = 16, offset = 3 },
    { sx = 73, sy = 0, width = 7, height = 16, offset = 0, fliph = true },
}

COL_SKY = 12
COL_GROUND = 3
COL_TEXT = 9
COL_TEXT_FLASH = 7

SEG_RIGHT = 1
SEG_STRAIGHT = 0
SEG_LEFT = -1

SCENES = {
    { pos = 0, pal = {} },
    { pos = 2000, pal = { [3] = 2, [12] = 14 } },
    { pos = 4000, pal = { [3] = 5, [12] = 1 } },
}

-- uh oh it's a state machine
STATE_DRIVING = 0
STATE_FINISHED = 1
STATE_NOT_STARTED = 2
STATE_GAME_OVER = 3

gameState = STATE_NOT_STARTED
frame = 0
driveTextCounter = 0

car = {
    maxSpeed=80,
    maxAccel=0.5,
    maxTurnAccel = 0.25,
    brakeAccel=-1.5,

    -- current state
    speed=0,
    accel=0,
    prevAccel=nil,
    pos=1,
    xpos=56,
    direction=0, -- -1 left, 1 right
    accelerating=false,
    braking=false,
    curSeg=nil,
    paletteSwap={},

    update=function(self)
        -- accel
        if self.braking then
            self.prevAccel = (self.prevAccel == nil and self.accel or self.prevAccel)
            self.accel = self.brakeAccel
        else
            if self.prevAccel != nil then
                self.accel = self.prevAccel
                self.prevAccel = nil
            end

            if self.accelerating then
                self.accel += 0.05
            else
                self.accel = -self.maxAccel
            end
        end

        if self.direction != 0 then
            self.xpos += self.direction * 2
            self.accel = min(self.accel, self.maxTurnAccel)
        end

        if self.accel > self.maxAccel then
            self.accel = self.maxAccel
        end

        -- speed
        if self.speed >= 0 then
            self.speed += self.accel
            if self.speed < 0 then self.speed = 0 end
            if self.speed > self.maxSpeed then self.speed = self.maxSpeed end
            self.pos += self.speed / 20
        end

        if self.speed == 0 then
            self.accel = 0
        end

        if self.curSeg != nil then
            self.xpos += -self.curSeg.seg.dir * (self.speed / self.maxSpeed) * 2
        end

        -- off track
        if self.xpos < 0 or self.xpos > 128 then
            if self.speed > self.maxSpeed/4 then
                self.accel = -self.maxAccel
            end

            self.xpos = max(min(self.xpos, 152), -42)
        end
    end,

    stop=function(self, x)
        self.speed = 0
        self.accel = 0
    end,

    checkCollision=function(self, x)
        return abs((self.xpos + 12) - x) < 12
    end,
}

updateq = {}

eventFsm = nil
timer = 0
powerups = {}
timePowerupSpawned = false

function _init()
    cls()
end

function _draw()
    cls()

    drawBackground()
    if gameState == STATE_NOT_STARTED then
        drawRoad()
        drawCar()
        drawAttract()
    elseif gameState == STATE_DRIVING then
        sfx(0, SFX_CHANNEL_CAR)
        drawRoad()
        drawCar()
        drawCollectedPowerups()

        if driveTextCounter < 100 then
            drawDriveText()
            driveTextCounter += 1
        end

        if eventFsm != nil then
            eventFsm.draw()
        end
        drawTimer()
    elseif gameState == STATE_GAME_OVER then
        drawRoad()
        drawCar()
        drawGameOverText()
    else
        sfx(-1, 0)
        drawFinishText()
    end

    frame += 1
end

function _update()
    car.curSeg = getSeg(track, car.pos, true)

    if gameState == STATE_NOT_STARTED then
        updateAttract()
    elseif gameState == STATE_DRIVING then
        if eventFsm == nil then
            eventFsm = makeEventFsm()
        end
        updateTimer()
        updateCar()
        updatePowerUps()
        eventFsm.update()

        -- generate more track if we're near the end
        if car.curSeg and car.curSeg.seg == track[#track - 1] then
            local newTrack = generateTrack(10)
            local offset = #track
            track[#track].isFinish = false
            for i = 1, #newTrack do
                track[offset + i] = newTrack[i]
            end
        end

    elseif gameState == STATE_GAME_OVER then
        -- if btnp(4) then
        --     run()
        -- end
    end

    for item in all(updateq) do
        item.update(item)
    end

    updateq = {}
end

function updateTimer()
    -- just gonna be lazy and count on 30 fps updates
    timer -= 1/30
    if timer <= 0 then
        gameState = STATE_GAME_OVER
        sfx(-1, SFX_CHANNEL_CAR)
    elseif timer < 15 and not timePowerupSpawned then
        timePowerupSpawned = true
    end
end

function updatePowerUps()
    local foundCigs = false
    for pup in all(powerups) do
        if pup.name == 'cigs' then
            foundCigs = true
        end

        if pup.collected then
            if pup.collectedTimer == 0 then
                del(powerups, pup)
            else
                pup.collectedTimer -= 1
            end
        elseif pup.pos - car.pos < 10 then
            local pupX = pup.xpos + 64 + (pup.anim[1].width/2)
            if car:checkCollision(pupX) then
                pup:onPickup()
                pup.collected = true
                pup.collectedTimer = PICKUP_COLLECTED_TIMER
            elseif pup.pos - car.pos < 0 then
                del(powerups, pup)
            end
        end
    end

    if (flr(timer) == 20 or flr(timer) == 5) and not foundCigs then
        add(powerups, makeCigs())
    end
end

function makeCigs()
    return {
        name = 'cigs',
        pos = car.pos + 200,
        xpos = rnd(64) - 32,
        anim = CIG_FRAMES,
        message = "+20 seconds",
        onPickup=function(self)
            timer += 20
        end,
    }
end

function updateAttract()
    if btn(4) then
        gameState = STATE_DRIVING
        timer = INIT_TIMER
        music(0)
    end
end

function updateCar()
    car.accelerating = btn(4)
    car.braking = btn(5)

    car.direction = 0
    if btn(0) then
        car.direction = -1
    end
    if btn(1) then
        car.direction = 1
    end

    if car.curSeg == nil or car.curSeg.seg.isFinish then
        gameState = STATE_FINISHED
    end

    rpm = (car.speed % (car.maxSpeed/3 + 1)) + car.speed / 5
    poke(0x3200, bor(rpm * 0.45, 0x40))
    poke(0x3200 + 1, 0x7)
    poke(0x3200 + 2, bor(rpm * 0.65, 0xc0))
    poke(0x3200 + 3, 0x4)

    curSeg = getCu

    add(updateq, car)
end

roadLineOffsets = {}

function drawRoad()
    local curSeg = car.curSeg

    for y = 128 - ROAD_HEIGHT, 128 do
        local z = abs(-64 / (y - 64))
        local scale = 1/z
        local width = 128 * scale
        local skew = (64 - (car.xpos + 8)) * scale
        local margin = (128 - width) / 2
        local texCoord = (z * 8 + car.pos) % 8

        local curveOffset = 0
        if curSeg != nil and curSeg.seg.dir != SEG_STRAIGHT then
            local curveScale = 1 - abs((curSeg.segPos - (curSeg.seg.length / 2)) / (curSeg.seg.length / 2))
            local distScale = 1 - ((y - (128 - ROAD_HEIGHT)) / ROAD_HEIGHT)
            curveOffset = sin(-curSeg.seg.dir * curveScale / 4 * distScale / (scale * 16)) * distScale * 25
        end

        roadLineOffsets[y] = { curveOffset = curveOffset, skew = skew }

        local ySeg = getSeg(track, car.pos + z * 7, false) -- i don't know why 7 works here
        if ySeg != nil and ySeg.seg.isFinish then
            palt(0, false)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_FINISH, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1)
            palt()
        else
            sspr(SPR_ROAD, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
            sspr(SPR_ROAD, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1, true)
        end

        local proj = car.pos + z * 8
        local pproj = car.pos + (abs(-64 / (y - 63))) * 8
        local nproj = car.pos + (abs(-64 / (y - 65))) * 8
        if ySeg != nil then
            for name in all(ySeg.seg.hazards) do
                local density = 32
                local hazard = HAZARDS[name]
                if proj % density < pproj % density and proj % density < nproj % density then
                    local xpos1 = (width/2) + 64
                    local xpos2 = (width/2) - 64
                    local height = hazard.height * scale * 2
                    local width = hazard.width * scale * 2
                    if hazard.palt != nil then
                        palt(hazard.palt, true)
                        palt(0, false)
                    end

                    if name != 'turnSign' or ySeg.seg.dir == SEG_LEFT then
                        drawAndCheckHazard(hazard,
                            xpos1 + skew + curveOffset, y-height,
                            width, height, false, true)
                    end
                    if name != 'turnSign' or ySeg.seg.dir == SEG_RIGHT then
                        drawAndCheckHazard(hazard,
                            (skew + curveOffset) - xpos2 - width, y-height,
                            width, height, true, false)
                    end
                    palt()
                end
            end
        end

        for powerup in all(powerups) do
            local projDiff = abs(powerup.pos - proj)
            if not powerup.collected and projDiff < abs(powerup.pos - nproj) and projDiff < abs(powerup.pos - pproj) then
                local animFrame = powerup.anim[flr((frame/4) % #powerup.anim) + 1]
                local x = 64 + animFrame.offset + skew + curveOffset + (scale * powerup.xpos)
                palt(0, false) -- TODO this should be per sprite not a blanket thing
                sspr(animFrame.sx, animFrame.sy,
                    animFrame.width, animFrame.height,
                    x, 64,
                    animFrame.width * scale * 2, animFrame.height * scale * 2,
                    animFrame.fliph)
                palt()
            end
        end

        pal()
    end
end

function drawAndCheckHazard(hazard, dx, dy, dw, dh, fliph, isLeft)
    sspr(hazard.sx, hazard.sy, hazard.width, hazard.height, dx, dy, dw, dh, fliph)
    if dy + dh >= 110 then
        local x = -8
        if isLeft then
            x = 136
        end
        local xCol = x - hazard.width/2
        if isLeft then
            xCol = x + hazard.width/2
        end
        if car:checkCollision(xCol) then
            car:stop()
        end
    end
end

function drawCar()
    local sprX = 32
    local width = 32
    local height = 24
    local split = 4
    local y = 100

    if car.xpos < -16 or car.xpos > 128 then
        if car.speed > 0 and frame % 3 == 0 then
            y += 1
        end
    end

    if car.braking then
        pal(2, 8, 0)
    end

    -- TODO fix duplicate palaetteSwap stuff

    if car.direction != 0 then
        local splitWidth = width/split

        pal(7, 4, 0) -- white
        pal(15, 4, 0) -- brown
        pal(12, 4, 0) -- blue
        sspr(sprX, 8, width, height, 64-width/2 + car.direction, y)
        pal()

        for k, v in pairs(car.paletteSwap) do
            pal(k, v)
        end

        if car.braking then
            pal(2, 8, 0)
        end

        for i = 0, split - 1 do
            local sliceX = i * splitWidth
            local offset = i * car.direction
            if car.direction == 1 then
                offset += 1
            end
            sspr(
                sprX + sliceX, 8,
                splitWidth, height,
                64 - (width/2) + sliceX, y + (offset - (car.direction * split/2))
            )
        end
    else
        for k, v in pairs(car.paletteSwap) do
            pal(k, v)
        end
        sspr(sprX, 8, width, height, 64-width/2, y)
    end
    pal()

    car.paletteSwap={}
end

function drawTimer()
    drawBigNumberShadowed(flr(timer), 64, 6)
end

function drawBigNumberShadowed(num, x, y)
    pal(7, 2)
    drawBigNumber(num, x, y+1)
    pal()
    drawBigNumber(num, x, y)
end

function drawBigNumber(num, x, y)
    -- 2.1 precision
    local decimal = false
    local width = 8
    if num >= 10 then
        width += 8
    end
    if flr(num) != num then
        decimal = true
        width += 11
    end

    local curX = x - width/2
    if num >= 10 then
        local d1 = flr(num / 10)
        spr(SPR_0 + d1, curX, y)
        curX += 8
    end
    local d2 = flr(num % 10)
    spr(SPR_0 + d2, curX, y)
    curX += 9

    if decimal then
        local d3 = (num - flr(num)) * 10
        pset(curX, y + 7, 7)
        curX += 2
        spr(SPR_0 + d3, curX, y)
    end
end

function drawAttract()
    printShadowed('press z to start', 64, 42, 9)
    printShadowed('Z: ACCELERATE X: BRAKE', 64, 50, 9)
end

function drawBackground()
    local currentScene
    for scene in all(SCENES) do
        if car.pos > scene.pos then
            currentScene = scene
        end
    end

    if currentScene != nil then
        for k, v in pairs(currentScene.pal) do
            pal(k, v)
        end
    end

    rectfill(0, 0, 128, 56, COL_SKY)
    rectfill(0, 72, 128, 128, COL_GROUND)
    sspr(0, 32, 8, 16, 0, 56, 128, 16)
    pal()
end

function drawFinishText()
    local width = 32
    local height = 14
    wigglyTiledSpr(8, 0, 56 - width/2, 56 - height/2, width + 16, height * 2)
    wigglySspr(0, 96, width, height, 64 - width/2, 64 - height/2)
end

function drawDriveText()
    local width = 36
    local height = 10
    wigglySspr(38, 96, width, height, 64 - width/2, 42)
end

function drawGameOverText()
    local width = 100
    local height = 15
    local y = 32 - height/2
    pal(7, 10)
    wigglySspr(0, 64, width, height, 64 - width/2, y - height - 1)
    pal(7, 9)
    wigglySspr(0, 64, width, height, 64 - width/2, y)
    pal(7, 8)
    wigglySspr(0, 64, width, height, 64 - width/2, y + height + 1)
    pal()

    local miles = flr(car.pos / 100) / 10
    local droveY = 62
    local boxWidth = 72
    local boxMargin = (128-boxWidth)/2

    rectfill(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 2)
    rect(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 4)

    printShadowed('results', 64, droveY, 7)

    printShadowed('you drove', 64, droveY + 9, COL_TEXT)
    drawBigNumber(miles, 64, droveY + 17)
    printShadowed('miles', 64, droveY + 28, COL_TEXT)
    printShadowed('- good job -', 64, droveY + 40, getFlashingCol())
    printShadowed('z to reset', 64, droveY + 53, COL_TEXT)
end

function drawCollectedPowerups()
    for pup in all(powerups) do
        if pup.collected then
            local animFrame = pup.anim[1]
            local a = pup.collectedTimer/PICKUP_COLLECTED_TIMER
            printShadowed(pup.message, 64, 64 + (16 * a), getFlashingCol())
        end
    end
end

function wigglyTiledSpr(sx, sy, dx, dy, width, height)
    local sliceWidth = 4
    local slices = flr(width/sliceWidth)
    for i = 0, slices do
        local yOffset = sin(i / slices + (-frame/16)) * 2

        pal()
        if yOffset < -1 then
            pal(7 ,6)
        end

        for y = 0, height, 8 do
            sspr(sx, sy,
                sliceWidth, 8,
                dx + (i * sliceWidth), dy + yOffset + y)
        end
    end
end

function wigglySspr(sx, sy, sw, sh, dx, dy)
    local sliceWidth = 4
    local slices = flr(sw/sliceWidth)
    for i = 0, slices do
        local yOffset = sin(i / slices + (-frame/16)) * 2
        sspr(sx + i * sliceWidth, sy,
            sliceWidth, sh,
            dx + (i * sliceWidth), dy + yOffset)
    end
end

function generateTrack(segCount)
    -- local segCount = 10 + rnd(10)
    local track = {}
    for i = 1, segCount do
        -- don't repeat the same anything twice in a row
        local newSeg
        if #track == 0 then
            newSeg = createSeg(i, 100 + flr(rnd(100)), SEG_STRAIGHT)
        else
            local prevSeg = track[#track]
            -- prefer curve if straight, prefer straight if curve
            local shouldChangeCurve = 75 > rnd(100)
            local nextDir = prevSeg.dir
            if shouldChangeCurve then
                if prevSeg.dir != SEG_STRAIGHT then
                    nextDir = 0
                else
                    local r = rnd(100)
                    nextDir = (r <= 50 and SEG_LEFT or SEG_RIGHT)
                end
            end
            newSeg = createSeg(i, 100 + flr(rnd(250)), nextDir)
        end
        add(track, newSeg)
    end
    add(track, createSeg(segCount + 1, 2, 0))
    track[#track].isFinish = true
    return addHazards(track)
end

-- for real why is lua so bad
HAZARD_NAMES = {'lamp', 'turnSign'}
HAZARDS = {
    lamp = {
        sx = 8,
        sy = 32,
        width = 8,
        height = 32
    },
    turnSign = {
        sx = 16,
        sy = 32,
        width = 16,
        height = 32,
        palt = 11,
    }
}

function addHazards(track)
    for seg in all(track) do
        if rnd(10) < 10 then
            local amount = flr(rnd(seg.length/10))
            local name = HAZARD_NAMES[flr(rnd(#HAZARD_NAMES)) + 1]
            if (name == 'turnSign' and seg.dir != SEG_STRAIGHT) or name != 'turnSign' then
                seg.hazards = { name }
            end
        end
    end
    return track
end

function createSeg(id, length, direction)
    return {
        id=id,
        length=length,
        dir=direction,
        hazards={},
    }
end

function getSeg(track, pos, remove)
    local sum = trackOffset
    local itemsToRemove = {}
    local foundSeg = nil
    for i = 1, #track  do
        local seg = track[i]
        if pos > sum and pos < (sum + seg.length) then
            foundSeg = {
                seg=seg,
                segPos=pos - sum,
                totalPos=(sum + seg.length) - pos
            }
            break
        elseif remove then
            itemsToRemove[i] = sum + seg.length
        end
        sum += seg.length
    end

    -- remove segs behind the car
    for k, v in pairs(itemsToRemove) do
        -- using del here because in theory there's only ever one thing in
        -- itemsToRemove
        trackOffset = v
        del(track, track[k])
    end

    return foundSeg
end

-- TODO give states real names
EVT_STATE_IDLE = 1
EVT_STATE_1 = 2
EVT_STATE_SUCCESS = 3
EVT_STATE_FAILURE = 4

--[[
  2
0   1    4 5
  3
]]
U = 2
D = 3
L = 0
R = 1
EVENTS = {
    {
        pattern = {R, D, U, U},
        name = 'your beer ran out!!',
        messages = {'toss it', 'grab it', 'crack it', 'chug it'},
        timer = 90,
        failure = {
            message = 'you spilled it everywhere!!',
            timer = 30,
            action = function()
                car.direction = 1
                car.paletteSwap[12] = 9
            end
        }
    },
    {
        pattern = {D, L, R, L},
        name = 'the kids are makin\' noise!!',
        messages = {'turn around', 'hoot' ,'holler', 'whoop'},
        timer = 90,
        failure = {
            message = 'dang kids!!',
            timer = 30,
            action = function()
                if frame % 14 < 7 then
                    car.paletteSwap[12] = 14
                    car.direction = -1
                else
                    car.paletteSwap[12] = 8
                    car.direction = 1
                end
            end
        }
    },
    {
        pattern = {L, L, R, L},
        name = 'sports aren\'t on the radio!!',
        messages = {'where', 'are' ,'the', 'sports'},
        timer = 90,
        failure = {
            message = 'i\'m missing the game!!',
            timer = 30,
            action = function()
                car.braking = true
            end
        }
    },
}

function makeEventFsm()
    local fsm = {}

    fsm.state= EVT_STATE_IDLE
    fsm.timer = 100 + rnd(100)
    fsm.frames = 1
    fsm.eventCounter = 0

    fsm.update = function()
        fsm.frames += 1
        if fsm.state == EVT_STATE_IDLE then
            if fsm.timer > 0 then
                fsm.timer -= 1
            else
                fsm.state = EVT_STATE_1
                fsm.eventCounter += 1
                fsm.event = EVENTS[flr(rnd(#EVENTS) + 1)]
                fsm.combo = {}
                fsm.timer = fsm.event.timer
                if fsm.eventCounter > 1 then
                    fsm.timer *= max(0.5, 1 - fsm.eventCounter/16)
                end
            end
        elseif fsm.state == EVT_STATE_1 then
            if #fsm.combo == #fsm.event.pattern then
                fsm.state = EVT_STATE_SUCCESS
                fsm.timer = 60
                return
            end

            if fsm.timer <= 0 then
                fsm.failure = fsm.event.failure
                fsm.state = EVT_STATE_FAILURE
                fsm.failureTimer = fsm.failure.timer
                fsm.timer = 60
                return
            end

            fsm.timer -= 1

            local nextComboChar = fsm.event.pattern[#fsm.combo + 1]
            if btnp(nextComboChar) then
                add(fsm.combo, nextComboChar)
            elseif band(btnp(), 0xF) > 0 then
                fsm.combo = {}
            end
        else
            if fsm.state == EVT_STATE_SUCCESS or fsm.state == EVT_STATE_FAILURE then
                if fsm.timer > 0 then
                    fsm.timer -= 1
                else
                    fsm.state = EVT_STATE_IDLE
                    fsm.timer = 50 + rnd(100) + max(0, 200 - fsm.eventCounter*30)
                    fsm.event = nil
                    fsm.combo = {}
                end
            end

            if fsm.state == EVT_STATE_FAILURE then
                if fsm.failureTimer > 0 then
                    fsm.failureTimer -= 1
                    fsm.failure.action()
                end
            end
        end
    end

    fsm.draw = function()
        local starty = 24
        if fsm.state == EVT_STATE_1 then
            printShadowed(fsm.event.name, 64, starty+2, 9)

            if #fsm.combo < #fsm.event.messages then
                printShadowed(fsm.event.messages[#fsm.combo + 1], 64, starty+11, getFlashingCol())
            end

            -- gordon bennet
            for i = 1, #fsm.event.pattern do
                local sprite = 2
                local flipx = false
                local flipy = false
                local char = fsm.event.pattern[i]
                local comboChar = fsm.combo[i]
                if (char == 3) flipy = true
                if (char == 1) sprite = 3
                if (char == 0) sprite = 3 flipx = true
                if comboChar != char then
                    pal(7, 4)
                end
                spr(sprite, 46 + (i - 1) * 9, starty+20, 1, 1, flipx, flipy)
                pal()
            end

            local timeLeft = fsm.timer/fsm.event.timer
            line(46, starty+29, 46 + timeLeft * 36, starty+29)
        elseif fsm.state == EVT_STATE_SUCCESS then
            printShadowed('success!!', 64, starty+2, getFlashingCol())
        elseif fsm.state == EVT_STATE_FAILURE then
            printShadowed(fsm.failure.message, 64, starty+2, getFlashingCol())
        end
    end

    return fsm
end

function getFlashingCol()
    if (frame % 4) <= 1 then
        return COL_TEXT_FLASH
    end
    return COL_TEXT
end

function printShadowed(str, x, y, col)
    -- jesus
    printCentered(str, x, y + 2, 2)
    printCentered(str, x-1, y + 2, 2)


    printCentered(str, x, y - 1, 4)
    printCentered(str, x+1, y - 1, 4)
    printCentered(str, x-1, y - 1, 4)

    printCentered(str, x+1, y, 4)
    printCentered(str, x-1, y, 4)

    printCentered(str, x, y + 1, 4)
    printCentered(str, x+1, y + 1, 4)
    printCentered(str, x-1, y + 1, 4)


    printCentered(str, x, y, col)
end

function printCentered(str, x, y, col)
    print(str, x - #str/2 * 4, y, col)
end

function printTable(tbl, cb)
    output = formatTable(tbl)
    if cb then
        cb(output)
    else
        print(output)
    end
end

function formatTable(tbl)
    local output = ''
    for k, v in pairs(tbl) do
        output = output .. k .. ': '
        if type(v) == 'string' or type(v) == 'number' then
            output = output .. v .. ' '
        elseif type(v) == 'boolean' then
            output = output .. (v and 'T' or 'F') .. ' '
        elseif type(v) == 'table' then
            output = output .. formatTable(v) .. ' '
        else
            output = output .. '? '
        end
    end
    return '{ ' .. output .. ' }'
end

track = generateTrack(4)
trackOffset = 0

__gfx__
7ddddddd557755770004400000044000000000000000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
7ddddddd557755770047740000047400000000000000000000000000000000008777777788777822200000000000000000000000000000000000000000000000
7ddddddd775577550477774044447740000000000000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
7ddddddd775577554777777447777774000000000000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
8dddddd6557755774447744447777774000000000000000000000000000000008888788888888822200000000000000000000000000000000000000000000000
8dddddd6557755770047740044447740000000000000000000000000000000008887778888888822200000000000000000000000000000000000000000000000
8dddddd677557755004774000004740000000000000000000000000000000000887f7f7888878822200000000000000000000000000000000000000000000000
8dddddd677557755004444000004400000000000000000000000000000000000877f8f77887f7822200000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000777fff7777797766600000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000077777777777f7766600000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000ffffff00000000000007007707777007766600000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000ff444444ff000000000007057707777057766600000000000000000000000000000000000000000000000
00000000666666660000000000000000000000000ff4444444444ff0000000007500000077500766600000000000000000000000000000000000000000000000
0000066600000000000000000000000000000000ffffffffffffffff000000007050606077050766600000000000000000000000000000000000000000000000
000064f00000000000000000000000000000000ffccccccccccccccff00000007777777777777766600000000000000000000000000000000000000000000000
00064f000000000000000000000000000000000fccccccccccccccccf00000008888888888888822200000000000000000000000000000000000000000000000
00064f00000000000000000000000000000000fccccccccccccccccccf0000000000000000000000000000000000000000000000000000000000000000000000
00064f00000000000000000000000000000000fccc7ccccccccccccccf0000000000000000000000000000000000000000000000000000000000000000000000
00064f0000000000000000000000000000000fccc7ccccccccccccccccf000000000000000000000000000000000000000000000000000000000000000000000
00644f0000000000000000000000000000000fcc77ccccccccccccccccf000000000000000000000000000000000000000000000000000000000000000000000
00644f000000000000000000000000000000fcc77ccccccccccccc7ccccf00000000000000000000000000000000000000000000000000000000000000000000
006444ffffffffff00000000000000000000fc77ccccccccccccc7cccccf00000000000000000000000000000000000000000000000000000000000000000000
00644444400000000000000000000000000fffffffffffffffff7ffffffff0000000000000000000000000000000000000000000000000000000000000000000
00660000000000000000000000000000000ffffffffffffffffffffffffff0000000000000000000000000000000000000000000000000000000000000000000
0086000000000000000000000000000000022f44445555555555544444f220000000000000000000000000000000000000000000000000000000000000000000
0066000000000000000000000000000000022f4444577c7c7c77544444f220000000000000000000000000000000000000000000000000000000000000000000
0086000000000000000000000000000000022f444447c7c7c7c7444444f220000000000000000000000000000000000000000000000000000000000000000000
0066000000000000000000000000000000022f44449999999999944444f220000000000000000000000000000000000000000000000000000000000000000000
0086600000000000000000000000000000077ffffffffffffffffffffff770000000000000000000000000000000000000000000000000000000000000000000
00666666666660000000000000000000000666566666666666666666656660000000000000000000000000000000000000000000000000000000000000000000
00006666666660000000000000000000000555555555555555555555555550000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000005550000000000000000555000000000000000000000000000000000000000000000000000000000000000000000
cccccccc06600000bbbbbbb00bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc66666000bbbbbb0990bbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333309905600bbbbb099990bbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc00000560bbbb09099990bbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc00000560bbb0900999990bbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560bb090000000990bb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc00000560b09900000009990b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
33333333000005600999900990099990000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc000005600999990990099990000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560b09999999009990b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc00000560bb099999900990bb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560bbb0999999990bbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560bbbb09999990bbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
cccccccc00000560bbbbb099990bbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560bbbbbb0990bbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
3333333300000560bbbbbb500bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb675bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000560bbbbbb665bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000550bbbbbb555bbbbbbb000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000777700000000777707777700000777770777777777700000000007777700000077700007770777777777707777770000000000000000000000000000000
00077777700000077777707777770007777770777777777700000000777777777000077700007770777777777707777777700000000000000000000000000000
00777777700000777777707777777077777770777777777700000007777777777700077700007770777777777707777777770000000000000000000000000000
07777700000007777777707770077777007770777000000000000077777000777770077700007770777000000007770007770000000000000000000000000000
07770000000007770077707770077777007770777000000000000077700000007770077700007770777000000007770000777000000000000000000000000000
77770000000077700077707770007770007770777000000000000777700000007777077700007770777000000007770000777000000000000000000000000000
77700000000077700077707770007770007770777777700000000777000000000777077700007770777777700007770000777000000000000000000000000000
77700000000777000077707770007770007770777777700000000777000000000777077700007770777777700007770000777000000000000000000000000000
77700007770777000077707770007770007770777777700000000777000000000777077700077770777777700007770007770000000000000000000000000000
77770007770777000077707770007770007770777000000000000777700000007777077700077700777000000007777777770000000000000000000000000000
07770007770777777777707770007770007770777000000000000077700000007770077700777700777000000007777777700000000000000000000000000000
07777707770777777777707770007770007770777000000000000077777000777770077707777000777000000007777777770000000000000000000000000000
00777777770777777777707770007770007770777777777700000007777777777700077777770000777777777707770007770000000000000000000000000000
00077777770777000077707770007770007770777777777700000000777777777000077777700000777777777707770000777000000000000000000000000000
00000777770777000077707770007770007770777777777700000000007777700000077770000000777777777707770000777000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
44444444444444444444444444444440444400888800000888800088088000880888880088000000000000000000000000000000000000000000000000000000
49999994994999499499449999949940499400888888008888880088088000880888880088000000000000000000000000000000000000000000000000000000
49999994994999999499499999949940499400880088008800088088008808800880000088000000000000000000000000000000000000000000000000000000
49944444994999999499499944449944499400880008808800088088008808800880000088000000000000000000000000000000000000000000000000000000
499994a4994994999499449994449999999400880008808880088088008808800888880088000000000000000000000000000000000000000000000000000000
49999444994994999499444999449999999400880008808888880088000888000888880088000000000000000000000000000000000000000000000000000000
499444e4994994499499444499949944499400880008808888800088000888000880000000000000000000000000000000000000000000000000000000000000
4994a44499499449949949999994994a499400880088008808800088000888000880000000000000000000000000000000000000000000000000000000000000
49944404994994499499499999449944499400888888008800880088000080000888880088000000000000000000000000000000000000000000000000000000
4444e40444444444444444444444444e444400888800008800088088000080000888880088000000000000000000000000000000000000000000000000000000
4aa44404aa4aa44aa4aa4aaaaa44aa444aa400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
44440004444444444444444444444440444400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
4ee40004ee4ee44ee4ee4eeeee44ee404ee400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
44440004444444444444444444444440444400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00777700007770000077770000777700000077700777777000007770077777700007700000777700000000000000000000000000000000000000000000000000
07777770007770000777777007777770000777700777777000077700077777700077770007777770000000000000000000000000000000000000000000000000
07700770000770000770077007700770007777700770000000777000000007700070070007700770000000000000000000000000000000000000000000000000
077007700007700000007770000077d007770770077777000777770000007770007dd700077d0770000000000000000000000000000000000000000000000000
077007700007700000077700000077d0077007700770d7700770d770000777000777777000777770000000000000000000000000000000000000000000000000
07700770000770000077700007700770077777770000077007700770007770000770077000077700000000000000000000000000000000000000000000000000
0777777000077000077777700777777007777777077777700777777007770000077dd77000777000000000000000000000000000000000000000000000000000
00777700000770000777777000777700000007700077770000777700077000000077770007770000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

__gff__
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__map__
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__sfx__
000200020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
011000000c04310000366250e0000c04310000110000c0430c0430c0000c0000c0000c04310000366250c0000c04310000366250e0000c04310000110000c0430c0430c0000c0000c0000c04310000366250c000
01100000021450e101021450214502145021450214502145021450214502145021450214502145021450914000145001000014500145001450014500145001450014500145001450014500145001450014507140
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__music__
02 01024344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344

