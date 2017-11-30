-- autocmd BufWritePost <buffer> silent make
PI = 3.14159
ROAD_HEIGHT = 58

-- uh oh it's a state machine
STATE_NOT_STARTED = 0
STATE_DRIVING = 1
STATE_FINISHED = 2
STATE_GAME_OVER = 3
STATE_ASCENDED = 4

gameState = STATE_NOT_STARTED

SPR_ROAD = 0
SPR_FINISH = 8
SPR_0 = 224
SPR_MID_BG = 64

SFX_CAR_CHANNEL = 2
SFX_CHANNEL = 3
SFX_CRASH = 4
SFX_PICKUP = 11
SFX_EVENT_START = 12
SFX_EVENT_ARROW = 13

INIT_TIMER = 60
DRIVE_TEXT_TIMER = 40
PICKUP_COLLECTED_TIMER = 60
GAME_OVER_TIMER = 90
ASCEND_TIMER = 300
FADE_TIMER = 120

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
    { -- fields
        id = 'fields',
        length = 2000,
        pal = {},
        hazards = { 'corn', 'sign' },
        events = {'beer', 'kids' },
    },
    { -- desert
        id = 'desert',
        length = 3000,
        pal = { [COL_GROUND] = 15 },
        hazards = { 'cactus', 'cactus', 'sign' },
        events = { 'beer', 'kids', 'sports', 'groove' },
    },
    { -- dusk
        id = 'dusk',
        length = 1000,
        pal = { [COL_GROUND] = 4, [COL_SKY] = 2 },
        hazards = { 'cactus', 'lamp', 'sign' },
        events = { 'kids', 'sports', 'cigs', 'groove' },
    },
    { -- city
        id = 'city',
        length = 3000,
        pal = { [COL_GROUND] = 1, [COL_SKY] = 0 },
        hazards = { 'building', 'neon', 'lamp' },
        events = { 'kids', 'cigs', 'pee' },
    },
    { -- candyland
        id = 'candyLand',
        length = 3000,
        pal = { [COL_GROUND] = 14, [COL_SKY] = 7 },
        floorSspr = 48,
        hazards = { 'candyCane', 'lolly' },
        events = { 'pee', 'foreboding' },
    },
    { -- gates of hell
        id = 'gates',
        length = 3000,
        pal = { [COL_GROUND] = 8, [COL_SKY] = 2 },
        floorSspr = 40,
        hazards = { 'gate', 'column' },
        events = { 'remorse' },
    },
    { -- hell
        id = 'hell',
        length = 5000,
        pal = { [COL_GROUND] = 10, [COL_SKY] = 8 },
        floorSspr = 32,
        hazards = { 'corpse', 'fire', 'not_doomguy' },
        events = { 'fire', 'repent' },
    },
    { -- purgatory
        id = 'purgatory',
        length = 3000,
        pal = { [COL_GROUND] = 5, [COL_SKY] = 6 },
        hazards = {},
        events = { 'nothing', },
    },
    { -- heaven
        id = 'heaven',
        length = 4000,
        pal = { [COL_GROUND] = 7 },
        floorSspr = 56,
        hazards = { 'heavenlyGate' },
        events = { 'peace' },
    },
    {
        id = 'ascention',
        length = 1000,
        pal = { [COL_GROUND] = 7 },
        hazards = {},
        events = {},
        noCurves = true,
        isFinish = true,
    }
}

frame = 0
driveTextTimer = 0
gameOverTimer = 0
gameOverStartFrame = nil
ascendTimer = 0
fadeTimer = 0
currentScene = SCENES[1]
trackOffset = 0
totalSegsGenerated = 0
completed = false

updateq = {}
eventFsm = nil

timer = INIT_TIMER
powerups = {}
attractMusicSpeed = peek(0x3200 + (68 * 5) + 65)

car = {
    maxSpeed=90,
    maxAccel=0.5,
    maxTurnAccel = 0.2,
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
    crashed=false,
    playedCrashSfx=false,
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
            self.xpos += self.direction * 2 * (min(10, self.speed + 5) / 10)
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
            self.xpos += -self.curSeg.seg.dir * ((self.speed / self.maxSpeed) * self.curSeg.seg.angle / 20)
        end

        -- off track
        if self.xpos < 0 or self.xpos > 128 then
            if self.speed > self.maxSpeed/4 then
                self.accel = -self.maxAccel
            end

            self.xpos = max(min(self.xpos, 152), -42)
        end

        if self.crashed and not self.playedCrashSfx then
            sfx(SFX_CRASH, SFX_CHANNEL)
            self.playedCrashSfx = true
        end
        if not self.crashed then self.playedCrashSfx = false end
    end,

    stop=function(self, x)
        self.speed = 0
        self.accel = 0
    end,

    checkCollision=function(self, x)
        return abs((self.xpos + 12) - x) < 12
    end,
}

function _init()
    cls()
    music(1)
    track = generateTrack(SCENES[1], 0)
    track.generatedScenes = { [SCENES[1].id] = true }
end

function _draw()
    cls()

    if gameState == STATE_NOT_STARTED then
        if driveTextTimer >= DRIVE_TEXT_TIMER/2 then
            drawReadyText()
        else
            drawAttract()
        end
    elseif gameState == STATE_DRIVING then
        drawBackground()
        drawRoad()
        drawCar()
        drawCollectedPowerups()

        if driveTextTimer > 0 then
            drawDriveText()
        end

        if eventFsm != nil then
            eventFsm.draw()
        end
        drawTimer()
        drawSpeed()
    elseif gameState == STATE_GAME_OVER then
        drawGameOverText()
    elseif gameState == STATE_FINISHED then
        drawBackground()
        drawRoad()
        car.paletteSwap[15] = 9
        car.paletteSwap[5] = 9
        car.paletteSwap[6] = 10
        car.paletteSwap[8] = 10
        car.paletteSwap[4] = 10
        drawAscendingCar()
        eventFsm.draw()
        -- sfx(-1)
        -- drawFinishText()
    elseif gameState == STATE_ASCENDED then
        if fadeTimer > FADE_TIMER then
            gameOverStartFrame = frame
            gameState = STATE_GAME_OVER
            sfx(-1, SFX_CAR_CHANNEL)
        else
            drawBackground()
            drawRoad()
            drawAscendingCar()
            fade(fadeTimer / 10)
        end
    end

    print(stat(1), 0, 0, 7)

    frame += 1
end

function _update()
    car.curSeg = getSeg(track, car.pos, true)

    if gameState == STATE_NOT_STARTED then
        if driveTextTimer > 0 then
            if driveTextTimer == DRIVE_TEXT_TIMER/2 then
                gameState = STATE_DRIVING
                timer = INIT_TIMER
                music(0)
            end
            driveTextTimer -= 1
        else
            updateAttract()
        end
    elseif gameState == STATE_DRIVING then
        sfx(0, SFX_CAR_CHANNEL)
        if eventFsm == nil then
            eventFsm = makeEventFsm()
        end
        updateTimer()
        updateCar()
        if gameOverTimer == 0 then
            updatePowerUps()
            eventFsm.update()
        end

        if driveTextTimer > 0 then
            driveTextTimer -= 1
        end

        checkScene = findScene(car.pos + 400) -- check if we're near the end of a scene
        currentScene = findScene(car.pos)

        if checkScene != currentScene and not track.generatedScenes[checkScene.id] then
            local totalTrackOffset = trackOffset
            for seg in all(tracK) do
                totalTrackOffset += seg.length
            end
            local newTrack = generateTrack(checkScene, totalTrackOffset)
            local offset = #track
            for i = 1, #newTrack do
                track[offset + i] = newTrack[i]
            end
            track.generatedScenes[checkScene.id] = true
        end
    elseif gameState == STATE_FINISHED then
        sfx(0, SFX_CAR_CHANNEL)
        eventFsm.update()
        updateCar()

        if ascendTimer > 1 then
            ascendTimer -= 1
        else
            gameState = STATE_ASCENDED
        end
    elseif gameState == STATE_ASCENDED then
        updateCar()
		fadeTimer += 1
    elseif gameState == STATE_GAME_OVER then
        if frame - gameOverStartFrame > 120 and btnp(4) then
            run()
        end
    end

    for item in all(updateq) do
        item.update(item)
    end

    updateq = {}
end

function updateTimer()
    -- just gonna be lazy and count on 30 fps updates
    if gameOverTimer > 1 then
        gameOverTimer -= 1
    elseif gameOverTimer == 1 then
        if currentScene.isFinish then
            gameState = STATE_FINISHED
            ascendTimer = ASCEND_TIMER
            eventFsm.clear()
            eventFsm.trigger('ascend')
        else
            gameOverStartFrame = frame
            gameState = STATE_GAME_OVER
            sfx(-1, SFX_CAR_CHANNEL)
        end
    elseif timer <= 0 then
        gameOverTimer = GAME_OVER_TIMER
        timer = 0
    elseif currentScene.isFinish then
        completed = true
        eventFsm.clear()
        gameOverTimer = GAME_OVER_TIMER
        music(2)
    else
        timer -= 1/30
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
                pup.collectedTimer -= 2
            end
        elseif pup.pos - car.pos < 10 then
            -- don't /2 becuase the pickup is scaled up by 2
            local pupX = pup.xpos + 64 + (pup.anim[1].width)
            if car:checkCollision(pupX) then
                pup:onPickup()
                pup.collected = true
                pup.collectedTimer = PICKUP_COLLECTED_TIMER
                sfx(SFX_PICKUP, SFX_CHANNEL)
            elseif pup.pos - car.pos < 0 then
                del(powerups, pup)
            end
        end
    end

    if not foundCigs then
        local r = (timer / 5) * 100
        if timer < 30 and (rnd(r) <= 4 or timer == 5) then
            add(powerups, makeCigs())
        end
    end
    if (flr(timer) == 20 or flr(timer) == 5) and not foundCigs then
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
    -- speed = 36, 36 ticks per beat. 2 bars of 3/4, 12 beats
    if stat(26) >= (attractMusicSpeed * 12) - 1  then
        music(1)
    end
    if btn(4) then
        driveTextTimer = DRIVE_TEXT_TIMER
        music(-1)
    end
end

function updateCar()
    local rpm = (car.speed % (car.maxSpeed/3 + 1)) + car.speed / 5
    poke(0x3200, bor(rpm * 0.45, 0x40))
    poke(0x3200 + 1, 0x5)
    poke(0x3200 + 2, bor(rpm * 0.65, 0xc0))
    poke(0x3200 + 3, 0x2)

    add(updateq, car)

    if completed then
        car.accelerating = true
        car.braking = false
        car.direction = 0
        return
    end

    if gameOverTimer > 0 then
        car.accelerating = false
        car.braking = true
        car.direction = 0
        return
    end

    car.accelerating = btn(4)
    car.braking = btn(5)

    car.direction = 0
    if btn(0) then
        car.direction = -1
    end
    if btn(1) then
        car.direction = 1
    end
end

roadLineOffsets = {}

function drawRoad()
    local curSeg = car.curSeg
    car.crashed = false -- what a terrible place to do this

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
            curveOffset = sin(-curSeg.seg.dir * curveScale / 4 * distScale / (scale * 16)) * distScale * curSeg.seg.angle
        end

        roadLineOffsets[y] = { curveOffset = curveOffset, skew = skew }

        local proj = car.pos + z * 8
        local yScene = findScene(proj)
        local ySeg = getSeg(track, proj, false) -- i don't know why 7 works here

        if yScene != nil and yScene.floorSspr then
            sspr(yScene.floorSspr, texCoord,
                8, 1,
                (scale * 64) + 64 + skew + curveOffset, y,
                width * 2, 1)
            sspr(yScene.floorSspr, texCoord,
                8, 1,
                (-scale * 64) + 64 + (skew + curveOffset - width * 2), y,
                width * 2, 1, true)
        end

        sspr(SPR_ROAD, texCoord, 8, 1, margin + skew + curveOffset, y, width/2 + 1, 1)
        sspr(SPR_ROAD, texCoord, 8, 1, margin + width/2 + skew + curveOffset, y, width/2, 1, true)

        local pproj = car.pos + (abs(-64 / (y - 63))) * 8
        local nproj = car.pos + (abs(-64 / (y - 65))) * 8
        if ySeg != nil then
            for name in all(ySeg.seg.hazards) do
                local hazard = HAZARDS[name]
                local density = hazard.density
                if proj % density < pproj % density and proj % density < nproj % density then
                    local xpos1 = (width/2) + 64
                    local xpos2 = (width/2) - 64
                    local height = hazard.height * scale * 2
                    local width = hazard.width * scale * 2

                    local drawLeft = false
                    local drawRight = false
                    if name != 'turnSign' then
                        if hazard.oneSide then
                            local r = (ySeg.seg.length % 10) > 5
                            drawLeft = r
                            drawRight = not r
                        else
                            drawLeft = true
                            drawRight = true
                        end
                    else
                        if ySeg.seg.dir == SEG_LEFT then drawLeft = true end
                        if ySeg.seg.dir == SEG_RIGHT then drawRight = true end
                    end

                    if drawLeft then
                        drawAndCheckHazard(hazard,
                            xpos1 + skew + curveOffset, y-height,
                            scale, true)
                    end
                    if drawRight then
                        drawAndCheckHazard(hazard,
                            (skew + curveOffset) - xpos2 - width, y-height,
                            scale, false)
                    end
                    palt()
                end
            end
        end

        for powerup in all(powerups) do
            local projDiff = abs(powerup.pos - proj)
            if not powerup.collected and projDiff < abs(powerup.pos - nproj) and projDiff < abs(powerup.pos - pproj) then
                local sc = max(0.25, scale)
                local animFrame = powerup.anim[flr((frame/4) % #powerup.anim) + 1]
                local x = 64 + animFrame.offset + skew + curveOffset + (sc * powerup.xpos)
                palt(0, false)
                sspr(animFrame.sx, animFrame.sy,
                    animFrame.width, animFrame.height,
                    x, 64,
                    animFrame.width * sc * 2, animFrame.height * sc * 2,
                    animFrame.fliph)
                palt()
                -- end
            end
        end

        pal()
    end
end

function drawHazard(hazard, dx, dy, dw, dh, isLeft)
    if hazard.heightScale != nil then
        dy -= dh * (hazard.heightScale - 1)
        dh *= hazard.heightScale
    end

    if hazard.widthScale != nil then
        if not isLeft then
            dx -= dw * (hazard.widthScale - 1)
        end
        dw *= hazard.widthScale
    end

    if hazard.palt then
        palt(0, false)
        palt(hazard.palt, true)
    end

    if hazard.pal then
        for k, v in pairs(hazard.pal) do
            pal(k, v)
        end
    end
    sspr(hazard.sx, hazard.sy, hazard.width, hazard.height, dx, dy, dw, dh, not isLeft)
    pal()
    if hazard.palt then
        palt(0, true)
        palt(hazard.palt, false)
    end
end

function drawAndCheckHazard(hazard, dx, dy, scale, isLeft)
    scale *= 2 -- ???
    local dblHazard = HAZARDS[hazard.doubleName]
    if dblHazard then
        if isLeft then
            drawHazard(dblHazard,
                       dx + (hazard.width * hazard.widthScale * scale) + 2, dy,
                       dblHazard.width * scale, dblHazard.height * scale,
                       isLeft)
        else
            drawHazard(dblHazard,
                       dx - (hazard.width * hazard.widthScale * scale) - 2, dy,
                       dblHazard.width * scale, dblHazard.height * scale,
                       isLeft)
        end
    end

    drawHazard(hazard, dx, dy, hazard.width * scale, hazard.height * scale, isLeft)

    -- only check the one closest to the road
    if dy + (hazard.height * scale) >= 110 then
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
            car.crashed = true
        end
    end
end

function drawAscendingCar()
    local sprX = 32
    local width = 32
    local height = 24
    local split = 4
    local y = flr(124 * (ascendTimer/ASCEND_TIMER) - 24)
    for k, v in pairs(car.paletteSwap) do
        pal(k, v)
    end
    sspr(16, 8, 16, 8, 64 - width/2, 108, 32, 16)
    sspr(sprX, 8, width, height, 64-width/2, y)
    pal()
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

function drawSpeed()
    drawBigNumberShadowed(flr(car.speed), 18, 114, 1)
    printShadowed('MPH', 26, 113, 7)
end

function drawTimer()
    if pget(64, 0) == 7 then
        drawBigNumberShadowed(flr(timer), 64, 6, false, 14)
    else
        drawBigNumberShadowed(flr(timer), 64, 6)
    end
end

function drawBigNumberShadowed(num, x, y, align, col)
    local colour = col or 7
    pal(7, 2)
    drawBigNumber(num, x, y+1, align)
    pal()
    pal(7, colour)
    drawBigNumber(num, x, y, align)
    pal()
end

function drawBigNumber(num, x, y, align)
    -- 2.1 precision
    local decimal = false
    local width = 8
    if num >= 10 then
        width += 8
    end
    if flr(num) != num then
        decimal = true
        width += 22
    end

    local curX = x - width/2
    if align == -1 then
        curX = x
    elseif align == 1 then
        curX = x - width
    end
    if num >= 10 then
        local d1 = flr(num / 10)
        spr(SPR_0 + d1, curX, y)
        curX += 8
    end
    local d2 = flr(num % 10)
    spr(SPR_0 + d2, curX, y)
    curX += 9

    if decimal then
        local d3 = flr((num - flr(num)) * 10)
        local d4 = flr((num - flr(num)) * 100 + 0.1) % 10
        pset(curX, y + 7, 7)
        curX += 2
        spr(SPR_0 + d3, curX, y)
        curX += 8
        spr(SPR_0 + d4, curX, y)
    end
end

function drawAttract()
    local roadY = 42
    local logoY = 32
    
    line(64, roadY - 16, 0, roadY + 48, 8)
    line(63, roadY - 16, -1, roadY + 48, 8)

    line(64, roadY - 16, 128, roadY + 48, 8)
    line(65, roadY - 16, 129, roadY + 48, 8)

    -- 70s
    sspr(0, 80, 28, 16, 31, logoY)
    -- dad
    sspr(29, 80, 33, 16, 64, logoY)
    
    local drvX = 32
    local kern = 4
    local width = 10
    pal(7, 9)
    -- d
    sspr(102, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern - 1
    -- r
    sspr(91, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern
    -- i
    sspr(69, 64, 3, 16, drvX, logoY + 19)
    drvX += 3 + kern
    -- v
    sspr(69, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern - 1
    -- i
    sspr(69, 64, 3, 16, drvX, logoY + 19)
    drvX += 3 + kern
    -- n
    sspr(113, 64, 10, 16, drvX, logoY + 19)
    drvX += width + kern
    -- '
    rect(drvX - kern + 1, logoY + 19, drvX - kern + 2, logoY + 21, 9)
    pal()

    local textY = 84
    printShadowed('press z to start', 64, textY, getFlashingCol())
    printShadowed('accelerate: \x8e brake: \x97', 64, textY + 10, 10)
    printShadowed('\x98 alligator 2017 \x98', 64, textY + 34, 9)
end

function drawBackground()
    if currentScene != nil then
        for k, v in pairs(currentScene.pal) do
            local col = v
            if type(v) == 'function' then
                col = v()
            end
            pal(k, col)
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
    local width = 32
    local height = 10
    local x = 40
    local y = 56
    pal(8, getFlashingCol(8, 9))
    -- D
    sspr(64, 80, 10, 16, x, y)
    x += 12
    -- R
    sspr(75, 80, 10, 16, x, y)
    x += 12
    -- I
    sspr(106, 80, 2, 16, x, y)
    x += 4
    -- V
    sspr(109, 80, 10, 16, x, y)
    x += 12
    -- E
    sspr(86, 80, 8, 16, x, y)
    x += 10

    pal()
end

function drawReadyText()
    local width = 32
    local height = 10
    local x = 36
    local y = 56
    -- R
    sspr(75, 80, 10, 16, x, y)
    x += 12
    -- E
    sspr(86, 80, 8, 16, x, y)
    x += 10
    -- A
    sspr(95, 80, 10, 16, x, y)
    x += 12
    -- D
    sspr(64, 80, 10, 16, x, y)
    x += 12
    -- Y
    sspr(72, 96, 10, 16, x, y)
    x += 12

    -- wigglySspr(38, 96, width, height, 64 - width/2, 42)
end

function drawGameOverText()
    local width = 101
    local height = 15
    local y = 32 - height/2
    pal(7, 10)
    wigglySspr(0, 64, width, height, 64 - width/2, y - height - 1)
    pal(7, 9)
    wigglySspr(0, 64, width, height, 64 - width/2, y)
    pal(7, 8)
    wigglySspr(0, 64, width, height, 64 - width/2, y + height + 1)
    pal()

    local miles = car.pos / 5400
    local droveY = 62
    local boxWidth = 72
    local boxMargin = (128-boxWidth)/2

    rectfill(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 2)
    rect(boxMargin, droveY + 2, 128-boxMargin, droveY + 62, 4)

    printShadowed('results', 64, droveY, 7)

    printShadowed('you drove', 64, droveY + 9, COL_TEXT)
    if completed then
        sspr(40, 120, 16, 8, 56, droveY + 17)
    else
        drawBigNumber(miles, 64, droveY + 17)
    end
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
        local x = sx + i * sliceWidth
        if x + sliceWidth >= sx + sw then
            local extra = (x + sliceWidth) - (sx + sw)
            sspr(sx + i * sliceWidth, sy,
                sliceWidth - extra, sh,
                dx + (i * sliceWidth), dy + yOffset)
        else
            sspr(sx + i * sliceWidth, sy,
                sliceWidth, sh,
                dx + (i * sliceWidth), dy + yOffset)
        end
    end
end

function generateTrack(scene, offset)
    local track = {}
    local totalLength = 0
    local pos = offset or 0
    while true do
        -- don't repeat the same anything twice in a row
        local newSeg
        if #track == 0 or scene.noCurves then
            newSeg = createSeg(i, 100 + flr(rnd(100)), SEG_STRAIGHT, 0)
        else
            local prevSeg = track[#track]
            -- prefer curve if straight, prefer straight if curve
            local shouldChangeCurve = 75 > rnd(100)
            local nextDir = prevSeg.dir
            local nextAngle = min(70, rnd(50) + 10 + rnd(totalSegsGenerated/10))
            if shouldChangeCurve then
                if prevSeg.dir != SEG_STRAIGHT then
                    nextDir = 0
                    nextAngle = 0
                else
                    local r = rnd(100)
                    nextDir = (r <= 50 and SEG_LEFT or SEG_RIGHT)
                end
            end
            newSeg = createSeg(i, 100 + flr(rnd(250)), nextDir, nextAngle)
        end
        if totalLength + newSeg.length >= scene.length then
            -- this seg would spill over into the next scene, bung a straight
            -- one on there and call it a day
            newSeg = createSeg(i, scene.length - totalLength, SEG_STRAIGHT, 0)
            add(track, newSeg)
            break
        end
        add(track, newSeg)

        totalSegsGenerated += 1
        pos += newSeg.length
        totalLength += newSeg.length
    end
    return addHazards(scene, track, offset)
end

function createSeg(id, length, direction, angle)
    return {
        id=id,
        length=length,
        dir=direction,
        angle=angle,
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

function findScene(pos)
    local prevScene = SCENES[1]
    local sum = 0
    for scene in all(SCENES) do
        if pos < sum then
            return prevScene
        end
        sum += scene.length
        prevScene = scene
    end
    -- uh oh, just return the last one???
    return SCENES[#SCENES]
end


-- for real why is lua so bad
-- HAZARD_NAMES = {'turnSign', 'lamp', 'corn', 'cactus', 'sign'}
HAZARDS = {
    turnSign = { -- this HAS to be first
        sx = 16,
        sy = 32,
        width = 16,
        height = 32,
        palt = 11,
        density = 32,
    },
    lamp = {
        sx = 8,
        sy = 32,
        width = 8,
        height = 32,
        density = 64,
    },
    corn = {
        sx = 32,
        sy = 32,
        width = 16,
        height = 32,
        density = 16,
        double = true,
    },
    cactus = {
        sx = 48,
        sy = 32,
        width = 16,
        height = 32,
        density = 32,
    },
    sign = {
        sx = 64,
        sy = 32,
        width = 16,
        height = 32,
        density = 64,
    },
    building = {
        sx = 80,
        sy = 32,
        width = 16,
        height = 32,
        density = 20,
        heightScale = 5,
        widthScale = 3,
        doubleName = 'building',
    },
    neon = {
        sx = 96,
        sy = 32,
        width = 16,
        height = 32,
        density = 24,
        heightScale = 3,
        widthScale = 3,
        doubleName = 'building',
        palt = 11,
    },
    corpse = {
        sx = 112,
        sy = 48,
        width = 8,
        height = 16,
        density = 64,
        heightScale = 2,
        widthScale = 2,
    },
    fire = {
        sx = 112,
        sy = 40,
        width = 8,
        height = 8,
        density = 16,
        heightScale = 3,
        widthScale = 2,
        doubleName = 'fire',
    },
    not_doomguy = {
        sx = 64,
        sy = 16,
        width = 16,
        height = 16,
        density = 128,
        heightScale = 2,
        widthScale = 2,
        oneSide = true,
    },
    column = {
        sx = 90,
        sy = 0,
        width = 12,
        height = 32,
        density = 64,
        heightScale = 2,
        widthScale = 2,
    },
    gate = {
        sx = 0,
        sy = 8,
        width = 16,
        height = 24,
        density = 64,
        heightScale = 2,
        widthScale = 2,
    },
    candyCane = {
        sx = 104,
        sy = 0,
        width = 8,
        height = 32,
        density = 64,
    },
    lolly = {
        sx = 80,
        sy = 16,
        width = 8,
        height = 16,
        density = 32,
        widthScale = 2,
        heightScale = 2,
    },
    heavenlyGate = {
        sx = 0,
        sy = 8,
        width = 16,
        height = 24,
        density = 64,
        heightScale = 2,
        widthScale = 2,
        pal = {
            [4] = 9,
            [5] = 9,
            [6] = 10,
            [7] = 10,
            [8] = 9,
        }
    }
}

function addHazards(scene, track, offset)
    -- printh('------')
    local pos = offset or 0
    printh('---- ' .. scene.id .. ' ----')
    for seg in all(track) do
        local sharpness = (seg.angle * 3) / seg.length
        if seg.dir != SEG_STRAIGHT and sharpness > 0.6 then
            seg.hazards = { 'turnSign' }
        else
            if scene and scene.hazards  then
                local name = scene.hazards[flr(rnd(#scene.hazards)) + 1] -- skip the first one
                seg.hazards = { name }
            end
        end
        printTable(seg, printh)
        pos += seg.length
    end
    return track
end

-- TODO give states real names
EVT_STATE_IDLE = 1
EVT_STATE_1 = 2
EVT_STATE_SUCCESS = 3
EVT_STATE_FAILURE = 4

U = 2
D = 3
L = 0
R = 1
EVENT_ARROW_COLOURS = {
    [U] = { dark = 1, light = 12 },
    [D] = { dark = 2, light = 8 },
    [L] = { dark = 3, light = 11 },
    [R] = { dark = 4, light = 10 },
}
EVENTS = {
    beer = {
        pattern = {R, D, R, U},
        name = 'your beer ran out!!',
        messages = {'toss it', 'grab it', 'crack it', 'chug it'},
        timer = 90,
        failure = {
            message = 'you spilled it everywhere!!',
            timer = 60,
            action = function(timer)
                if car.direction != 0 then
                    car.direction = -car.curSeg.seg.dir
                else
                    if timer < 30 then
                        car.direction = -1
                    else
                        car.direction = 1
                    end
                end
                car.paletteSwap[12] = 9
            end
        }
    },
    kids = {
        pattern = {U, L, R, L},
        name = 'the kids are makin\' noise!!',
        messages = {'shout', 'bellow' ,'holler', 'yell really loud'},
        timer = 90,
        failure = {
            message = 'dang kids!!',
            timer = 60,
            action = function(timer)
                if timer % 20 < 10 then
                    car.paletteSwap[12] = 14
                    car.direction = -1
                else
                    car.paletteSwap[12] = 8
                    car.direction = 1
                end
            end
        }
    },
    cigs = {
        pattern = {U, L, D, D},
        name = 'your cigarette went out!!',
        messages = {'grab another', 'light it', 'cough', 'hack' },
        timer = 90,
        failure = {
            message = 'oh no the withdrawals!!',
            timer = 30,
            action = function(timer, frame)
                car.braking = true
                if frame % 10 > 5 then
                    car.direction = 1
                else
                    car.direction = -1
                end
            end
        },
    },
    sports = {
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
    fire = {
        pattern = {D, L, U, R},
        name = 'i\'m on fire!!',
        messages = {'aaa', 'aaaa', 'aaaaa', 'aaaaaa'},
        timer = 60,
        failure = {
            message = 'aaaaaaaaaa',
            timer = 45,
            action = function(timer)
                car.paletteSwap[12] = 8
                car.accelerating = false
                if timer == 0 then
                    camera(0, 0)
                else
                    camera(timer % 3 - 1, -(timer % 3 - 1))
                end
            end
        },
    },
    remorse = {
        pattern = {D, D, D, D},
        name = 'i feel remorse for my actions!!',
        messages = {'quick', 'swallow', 'those', 'feelings'},
        timer = 90,
        failure = {
            message = 'the guilt!!',
            timer = 90,
            action = function(timer)
                car.direction = -car.direction
            end
        },
    },
    nothing = {
        pattern = {U, U, U, U},
        name = 'i feel',
        messages = {'nothing', 'nothing', 'nothing', 'nothing'},
        timer = 120,
        failure = {
            message = '\x8c emptiness \x8c',
            timer = 90,
            action = function(timer)
                car.paletteSwap[12] = 5
                car.paletteSwap[15] = 6
            end
        },
    },
    pee = {
        pattern = {L, R, L, R},
        name = 'i need to pee!!',
        messages = {'hold', 'it', 'hold', 'it'},
        timer = 60,
        failure = {
            message = 'dang crab juice!!',
            timer = 30,
            action = function(timer, frame)
                if frame % 10 > 5 then
                    car.direction = -1
                else
                    car.direction = 1
                end
            end
        },
    },
    groove = {
        pattern = {R, R, R, L},
        name = 'i slid out of my butt groove!!',
        messages = {'shimmy', 'slide', 'shimmy', 'shimmy'},
        failure = {
            message = 'oh no the ridges!!',
            timer = 60,
            action = function(timer)
                if timer % 20 < 10 then
                    car.direction = -1
                else
                    car.direction = 1
                end
            end
        }
    },
    foreboding = {
        pattern = {R, L, R, L},
        name = 'i have a sense of foreboding!!',
        messages = {'i\'m', 'sure', 'it\'s', 'nothing'},
        timer = 90,
        failure = {
            message = 'this doesn\'t bode well!!',
            timer = 30,
            action = function()
                car.braking = true
            end
        },
    },
    peace = {
        pattern = {L, U, U, R},
        name = 'i feel at peace!!',
        messages = {'there is', 'no need', 'to be', 'upset'},
        timer = 90,
        failure = {
            message = 'still at peace!!',
            timer = 60,
            action = function() end
        },
    },
    repent = {
        pattern = {U, D, U, D},
        name = 'i want to repent!!',
        messages = {'please', 'i', 'am', 'sorry'},
        timer = 90,
        failure = {
            message = 'help',
            timer = 30,
            action = function(timer)
                car.braking = true
                -- is this a good idea
                -- turns out no, unless i wanna redo track generation
                --[[
                for scene in all(SCENES) do
                    if scene.id == 'hell' then
                        scene.length += 500
                        printTable(scene, printh)
                    end
                end
                ]]
            end
        },
    },
    ascend = {
        pattern = {U, U, U, U},
        name = 'hello i am peter',
        messages = {'hello peter', 'i', 'am', 'dad'},
        timer = nil,
        failure = { timer = 0 },
    },
}

SFX_EVENTS = {
    [L] = 28 + 12,
    [U] = 32 + 12,
    [R] = 35 + 12,
    [D] = 37 + 12,
}

function makeEventFsm()
    local fsm = {}

    fsm.state= EVT_STATE_IDLE
    fsm.timer = 200 + rnd(100)
    fsm.frames = 1
    fsm.eventCounter = 0

    fsm.update = function()
        fsm.frames += 1
        if fsm.state == EVT_STATE_IDLE then
            if fsm.timer > 0 then
                fsm.timer -= 1
            else
                local eventName = currentScene.events[flr(rnd(#currentScene.events)) + 1]
                if eventName then
                    fsm.trigger(eventName)
                end
            end
        elseif fsm.state == EVT_STATE_1 then
            if #fsm.combo == #fsm.event.pattern then
                fsm.state = EVT_STATE_SUCCESS
                fsm.timer = 60
                return
            end

            if fsm.timer != nil and fsm.timer <= 0 then
                fsm.failure = fsm.event.failure
                fsm.state = EVT_STATE_FAILURE
                fsm.failureFrame = frame
                fsm.failureTimer = fsm.failure.timer
                fsm.timer = 60
                return
            end

            if fsm.timer != nil then fsm.timer -= 1 end

            local nextComboChar = fsm.event.pattern[#fsm.combo + 1]
            if btnp(nextComboChar) then
                add(fsm.combo, nextComboChar)

                local addr = 0x3200 + 68 * SFX_EVENT_ARROW
                poke(addr, SFX_EVENTS[nextComboChar])
                sfx(SFX_EVENT_ARROW, SFX_CHANNEL)
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
                    fsm.failure.action(fsm.failureTimer, fsm.failureFrame)
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
            local firstComboChar = true
            for i = 1, #fsm.event.pattern do
                local sprite = 2
                local flipx = false
                local flipy = false
                local char = fsm.event.pattern[i]
                local comboChar = fsm.combo[i]
                if (char == 3) then flipy = true end
                if (char == 1) then sprite = 3 end
                if (char == 0) then sprite = 3 flipx = true end
                if comboChar != char then
                    if firstComboChar then
                        -- pal(4, getFlashingCol(4, 9, 0.75))
                        pal(7, getFlashingCol(
                           EVENT_ARROW_COLOURS[char].dark,
                            EVENT_ARROW_COLOURS[char].light, 0.75))
                    else
                        pal(7, EVENT_ARROW_COLOURS[char].dark)
                    end
                    firstComboChar = false
                end
                palt(0, false)
                palt(11, true)
                spr(sprite, 46 + (i - 1) * 9, starty+20, 1, 1, flipx, flipy)
                pal()
                palt()
            end

            if fsm.timer != nil then
                local timeLeft = fsm.timer/fsm.event.timer
                line(46, starty+29, 46 + timeLeft * 36, starty+29)
            end
        elseif fsm.state == EVT_STATE_SUCCESS then
            printShadowed('success!!', 64, starty+2, getFlashingCol())
        elseif fsm.state == EVT_STATE_FAILURE then
            printShadowed(fsm.failure.message, 64, starty+2, getFlashingCol())
        end
    end

    fsm.clear = function()
        fsm.state = EVT_STATE_IDLE
        fsm.event = nil
        fsm.combo = nil
        fsm.timer = nil
        fsm.failureFrame = nil
        fsm.failureTimer = nil
    end

    fsm.trigger = function(eventName)
        fsm.state = EVT_STATE_1
        fsm.eventCounter += 1
        fsm.event = EVENTS[eventName]
        fsm.combo = {}
        fsm.timer = fsm.event.timer

        local addr = 0x3200 + 68 * SFX_EVENT_START
        for i in all(fsm.event.pattern) do
            poke(addr, SFX_EVENTS[i])
            addr += 2
        end
        sfx(SFX_EVENT_START, SFX_CHANNEL)
    end

    return fsm
end

function getFlashingCol(a, b, sc)
    local scale = 1
    if sc then scale = sc end
    if ((frame * scale) % 4) <= 1 then
        if b then return b end
        return COL_TEXT_FLASH
    end
    if a then return a end
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
    return '{ ' .. output .. '}'
end

function xorshift(a)
    -- wait i dont even need this...
    a = bxor(a, shl(a, 13))
    a = bxor(a, shr(a, 17))
    a = bxor(a, shl(a, 5))
    return a
end

-- track = generateTrack(4)

fadetable={
  {0,5,5,5,6,6,7},
  {1,13,13,13,6,6,7},
  {2,2,14,6,6,7,7},
  {3,3,6,6,6,6,7},
  {4,4,15,15,15,7,7},
  {5,5,6,6,6,6,7},
  {6,6,6,6,7,7,7},
  {7,7,7,7,7,7,7},
  {8,14,14,14,14,15,7},
  {9,9,10,15,15,15,7},
  {10,10,10,15,15,15,7},
  {11,11,11,6,7,7,7},
  {12,12,12,6,6,6,6},
  {13,13,6,6,6,6,7},
  {14,14,14,15,7,7,7},
  {15,15,15,15,7,7,7}
}

-- http://kometbomb.net/pico8/fadegen.html
function fade(i)
	for c=0,15 do
		if flr(i+1)>=8 then
			pal(c,7, 1)
		else
			pal(c,fadetable[c+1][flr(i+1)], 1)
		end
	end
end
