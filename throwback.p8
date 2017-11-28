pico-8 cartridge // http://www.pico-8.com
version 14
__lua__
-- autocmd BufWritePost <buffer> silent make
PI = 3.14159
ROAD_HEIGHT = 58
INIT_TIMER = 60

DRIVE_TEXT_TIMER = 40

-- uh oh it's a state machine
STATE_NOT_STARTED = 0
STATE_DRIVING = 1
STATE_FINISHED = 2
STATE_GAME_OVER = 3

gameState = STATE_NOT_STARTED

SPR_ROAD = 0
SPR_FINISH = 8
SPR_0 = 224
SPR_MID_BG = 64

SFX_CAR_CHANNEL = 2
SFX_CHANNEL = 3
SFX_CRASH = 4

PICKUP_COLLECTED_TIMER = 60
GAME_OVER_TIMER = 90

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
    -- pal, sky = 12, ground = 3
    {
        pos = 0,
        pal = {},
        hazards = { 'corn', 'sign' },
    },
    {
        pos = 2000,
        pal = { [3] = 15 },
        hazards = { 'cactus', 'cactus', 'sign' },
    },
    {
        pos = 4000,
        pal = { [3] = 4, [12] = 2 },
        hazards = { 'cactus', 'lamp', 'sign' },
    },
    {
        pos = 5000,
        pal = { [3] = 1, [12] = 0 },
        hazards = { 'building', 'neon', 'lamp' },
    },
    {
        pos = 6400,
        pal = { [3] = 1, [12] = 0 },
        hazards = { 'building', 'neon', 'lamp' },
    },
    {
        pos = 6500,
        pal = {
            [3] = 10,--function() return getFlashingCol(10, 9, 0.5) end,
            [12] = 8,
        },
        floorSspr = 32,
        hazards = { 'corpse', 'fire', 'not_doomguy' },
    },
}

frame = 0
driveTextTimer = 0
gameOverTimer = 0
currentScene = SCENES[1]
trackOffset = 0
totalSegsGenerated = 0

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
    else
        sfx(-1)
        drawFinishText()
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

        -- generate more track if we're near the end
        if car.curSeg and car.curSeg.seg == track[#track - 1] then
            local newTrack = generateTrack(3)
            local offset = #track
            track[#track].isFinish = false
            for i = 1, #newTrack do
                track[offset + i] = newTrack[i]
            end
        end

        for scene in all(SCENES) do
            if car.pos > scene.pos then
                currentScene = scene
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
    if gameOverTimer > 1 then
        gameOverTimer -= 1
    elseif gameOverTimer == 1 then
        gameState = STATE_GAME_OVER
        sfx(-1, SFX_CAR_CHANNEL)
    elseif timer <= 0 then
        gameOverTimer = GAME_OVER_TIMER
        timer = 0
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
    poke(0x3200 + 1, 0x7)
    poke(0x3200 + 2, bor(rpm * 0.65, 0xc0))
    poke(0x3200 + 3, 0x4)

    add(updateq, car)

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

    if car.curSeg == nil or car.curSeg.seg.isFinish then
        gameState = STATE_FINISHED
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

        if currentScene != nil and currentScene.floorSspr then
            sspr(currentScene.floorSspr, texCoord,
                 8, 1,
                 64 + skew + curveOffset, y,
                 width * 2, 1)
            sspr(currentScene.floorSspr, texCoord,
                 8, 1,
                 64 + (skew + curveOffset - width * 2), y,
                 width * 2, 1, true)
        end

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
    sspr(hazard.sx, hazard.sy, hazard.width, hazard.height, dx, dy, dw, dh, not isLeft)
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

function drawSpeed()
    -- sspr(0, 120, 26, 8, 2, 2)
    drawBigNumberShadowed(flr(car.speed), 18, 114, 1)
    printShadowed('MPH', 26, 113, 7)
    -- print(car.speed, 0, 0, 2)
end

function drawTimer()
    drawBigNumberShadowed(flr(timer), 64, 6)
end

function drawBigNumberShadowed(num, x, y, align)
    pal(7, 2)
    drawBigNumber(num, x, y+1, align)
    pal()
    drawBigNumber(num, x, y, align)
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
    printShadowed('Z: ACCELERATE X: BRAKE', 64, textY + 10, 9)
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

function generateTrack(segCount)
    local track = {}

    for i = 1, segCount do
        -- don't repeat the same anything twice in a row
        local newSeg
        if #track == 0 then
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
        add(track, newSeg)
        totalSegsGenerated += 1
    end
    return addHazards(track)
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
    }
}

function addHazards(track)
    local pos = trackOffset
    local carPos = car.pos - trackOffset
    printh('-----')
    for seg in all(track) do
        local sharpness = (seg.angle * 3) / seg.length
        printTable(seg, printh)
        printh(sharpness)
        if seg.dir != SEG_STRAIGHT and sharpness > 0.6 then
            seg.hazards = { 'turnSign' }
        else
            local hazardNames = nil
            for scene in all(SCENES) do
                if (pos + carPos + seg.length) > scene.pos then
                    hazardNames = scene.hazards
                end
            end

            if hazardNames then
                local name = hazardNames[flr(rnd(#hazardNames)) + 1] -- skip the first one
                seg.hazards = { name }
            end
        end
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
EVENTS = {
    {
        pattern = {R, D, U, U},
        name = 'your beer ran out!!',
        messages = {'toss it', 'grab it', 'crack it', 'chug it'},
        timer = 90,
        failure = {
            message = 'you spilled it everywhere!!',
            timer = 30,
            action = function(timer)
                if car.direction != 0 then
                    car.direction = -car.curSeg.seg.dir
                else
                    if timer < 15 then
                        car.direction = -1
                    else
                        car.direction = 1
                    end
                end
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
    fsm.timer = 200 + rnd(100)
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
                    printh(fsm.timer)
                    fsm.event = nil
                    fsm.combo = {}
                end
            end

            if fsm.state == EVT_STATE_FAILURE then
                if fsm.failureTimer > 0 then
                    fsm.failureTimer -= 1
                    fsm.failure.action(fsm.failureTimer)
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
    return '{ ' .. output .. ' }'
end

function xorshift(a)
    -- wait i dont even need this...
    a = bxor(a, shl(a, 13))
    a = bxor(a, shr(a, 17))
    a = bxor(a, shl(a, 5))
    return a
end

track = generateTrack(4)

__gfx__
7ddddddd5577557700044000000440009a98aa9a0000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
7ddddddd5577557700477400000474009aaaa9aa0000000000000000000000008777777788777822200000000000000000000000000000000000000000000000
7ddddddd775577550477774044447740999a9a9a0000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
7ddddddd7755775547777774477777749a8aaaa90000000000000000000000008888888888888822200000000000000000000000000000000000000000000000
8dddddd655775577444774444777777499aa999a0000000000000000000000008888788888888822200000000000000000000000000000000000000000000000
8dddddd65577557700477400444477409a989aaa0000000000000000000000008887778888888822200000000000000000000000000000000000000000000000
8dddddd677557755004774000004740099a9aa9a000000000000000000000000887f7f7888878822200000000000000000000000000000000000000000000000
8dddddd6775577550044440000044000999aaaa9000000000000000000000000877f8f77887f7822200000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000777fff7777797766600000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000077777777777f7766600000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000ffffff00000000000007007707777007766600000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000ff444444ff000000000007057707777057766600000000000000000000000000000000000000000000000
00000000666666660000000000000000000000000ff4444444444ff0000000007500000077500766600000000000000000000000000000000000000000000000
0000066600000000000000000000000000000000ffffffffffffffff000000007050606077050766600000000000000000000000000000000000000000000000
000064f00000000000000000000000000000000ffccccccccccccccff00000007777777777777766600000000000000000000000000000000000000000000000
00064f000000000000000000000000000000000fccccccccccccccccf00000008888888888888822200000000000000000000000000000000000000000000000
00064f00000000000000000000000000000000fccccccccccccccccccf0000000000000000000000000000000000000000000000000000000000000000000000
00064f00000000000000000000000000000000fccc7ccccccccccccccf0000000000055000000000000000000000000000000000000000000000000000000000
00064f0000000000000000000000000000000fccc7ccccccccccccccccf000000000555000000000000000000000000000000000000000000000000000000000
00644f0000000000000000000000000000000fcc77ccccccccccccccccf0000000005490b0000000000000000000000000000000000000000000000000000000
00644f000000000000000000000000000000fcc77ccccccccccccc7ccccf0000000355533b000000000000000000000000000000000000000000000000000000
006444ffffffffff00000000000000000000fc77ccccccccccccc7cccccf00000033333349000000000000000000000000000000000000000000000000000000
00644444400000000000000000000000000fffffffffffffffff7ffffffff000003b333bb4900000000000000000000000000000000000000000000000000000
00660000000000000000000000000000000ffffffffffffffffffffffffff0000049b443b0495000000000000000000000000000000000000000000000000000
0086000000000000000000000000000000022f44445555555555544444f220000004944400555000338998938398989300000000000000000000000000000000
0066000000000000000000000000000000022f4444577c7c7c77544444f220000004914300050000999888889989338800000000000000000000000000000000
0086000000000000000000000000000000022f444447c7c7c7c7444444f220000004111900000000888939398838893900000000000000000000000000000000
0066000000000000000000000000000000022f44449999999999944444f220000031109a90000080333898883933388800000000000000000000000000000000
0086600000000000000000000000000000077ffffffffffffffffffffff77000003309a7a9000000899383398899999900000000000000000000000000000000
0066666666666000000000000000000000066656666666666666666665666000003b009a90008000988989983388988800000000000000000000000000000000
00006666666660000000000000000000000555555555555555555555555550000008020980089800993888839383833300000000000000000000000000000000
0000000000000000000000000000000000000555000000000000000055500000000220222089a900938333899899889900000000000000000000000000000000
cccccccc06600000bbbbbbb00bbbbbbb000aa0000aa00000000000000000000000000000000000000055111111111110c1c1c1c1111111110000000000000000
cccccccc66666000bbbbbb0990bbbbbb00000900900a000000000003bb000000000000000000000055551aaaa11aaaa11aaaaaac1aa110010000000000000000
3333333309905600bbbbb099990bbbbb000000909000000000000003bf00000000000000000000005555111111111111caa00aa11aa110010000000000000000
cccccccc00000560bbbb09099990bbbb0000009900aa000000000033b3300000000000000000000055551111111111111a0aa0ac111111110000000000000000
cccccccc00000560bbb0900999990bbb00aa909909a0a00000000033bb300000000000000000000055551aaaa11aaaa1ca00a0a1111111110000000000000000
3333333300000560bb090000000990bb0a000999990000000000003bbb300000000000000000000055551aaaa11aaaa11aaaaaac100110010000000000000000
cccccccc00000560b09900000009990b000000999000000000000035bb30000000000000000000005555111111111111caa00aa1100110010000000000000000
333333330000056009999009900999900000003900000000003b0033bb300000000000000000000055551111111111111a0aa0ac111111110000000000000000
cccccccc00000560099999099009999000000033003bb00003bb3033bf300000888888888888888855551aaaa1155551caa00aa1111111110000008000000000
3333333300000560b09999999009990b000000330333bb00035b3033b3300000888888888787888855551aaaa11555511aaaaaac10011aa10000880000000000
cccccccc00000560bb099999900990bb0000003333000bb0033b3033bb30000087788888788788885555111111111111caa00aa110011aa10008800000000000
3333333300000560bbb0999999990bbb00000bbb300000b0033b303bbb300b30878777778787887855551111111111111a0aa0ac111111110089800000000000
3333333300000560bbbb09999990bbbb0000bbb3000bb00003bb3035bb303bb3877878788877777855551aaaa11aaaa1caa00aa1111111110899980000000000
cccccccc00000560bbbbb099990bbbbb0000bbb300bb3300035b3333bb303b53878788888788878855551aaaa11aaaa11aaaaaac10011001089a998000000000
3333333300000560bbbbbb0990bbbbbb00a3bb330bb003000333bb33bf303b3387788777777788885555111111111111ca0000a110011001089aa98000000000
3333333300000560bbbbbb500bbbbbbb003a35333bb0003000333333b3303b33888888888888888855551111111111110a0aa0ac11111111009aa90000000000
0000000000000560bbbbbb675bbbbbbb003333333b00000000333333bb303bb3005500000000550055551555511aaaa1caa00aa1111111110055455400000000
0000000000000560bbbbbb675bbbbbbb00bb3533300000000000353bbb333b53006500000000650055551555511aaaa11aaaaaac888888880006000400000000
0000000000000560bbbbbb675bbbbbbb0bbbb3533000000000000035bb3bb33300660000000066005555111111111111c1c1c1c1777777780004000400000000
0000000000000560bbbbbb675bbbbbbb0bb333330000000000000033bb3333330066000000006600555511111111111186500666067600780006000500000000
0000000000000560bbbbbb675bbbbbbb0b0003330000000000000033bf333330006600000000660055551aaaa11aaaa186607070707077780005000500000000
0000000000000560bbbbbb675bbbbbbb0b00003333bb000000000033b3353000006600000000660055551aaaa11aaaa186607070707070780008000400000000
0000000000000560bbbbbb675bbbbbbbb0000033333bb00000000033bb3000000066000000006600555511111111111186600776067600782008000500000000
0000000000000560bbbbbb675bbbbbbb00000033300bb0000000003bbb30000000660000000066005555111111111111c8677777777777788222000500000000
0000000000000560bbbbbb675bbbbbbb00bb0033300bb00000000035bb30000000660000000066005555155551155551ca888888888888880082000400000000
0000000000000560bbbbbb665bbbbbbb033bbb330000b00000000033bb30000000660000000066005555155551155551caacaaaa7aaaaaac0082000400000000
0000000000000560bbbbbb665bbbbbbb0303bb330000b00000000033bf30000000660000000066005555111111111111cadcadada7adaaac0822000500000000
0000000000000560bbbbbb665bbbbbbb3000bb330000000000000033b330000000660000000066005555111111111111cadcd5ddad75ddac2020200400000000
0000000000000560bbbbbb665bbbbbbb30000b330000000000000033bb300000006600000000660055551aaaa1155551ca5c75d5dd57d5dc2080200400000000
0000000000000560bbbbbb665bbbbbbb00000033000000000000003bbb300000006600000000660055551aaaa1155551ca5cd755dd5575dc2000200500000000
0000000000000560bbbbbb665bbbbbbb000000330000000000000035b330000000660000000066005555111111111111bc5c55555555555c0000004500000000
0000000000000550bbbbbb555bbbbbbb0000003300000000000000333350000000660000000066000055111111111111bbcccccccccccccc0282545500000000
00000777700000000777707777700000777770777777777700000000007777700000077700007770777777777707777770000077777000000777000077700000
00077777700000077777707777770007777770777777777700000000777777777000077700007770777777777707777777700077777770000777770077700000
00777777700000777777707777777077777770777777777700000007777777777700077700007770777777777707777777770077777777000777777077700000
07777700000007777777707770077777007770777000000000000077777000777770077700007770777000000007770007770077700777700777777777700000
07770000000007770077707770077777007770777000000000000077700000007770077700007770777000000007770000777077700077700777007777700000
77770000000077700077707770007770007770777000000000000777700000007777077700007770777000000007770000777077700007770777000777700000
77700000000077700077707770007770007770777777700000000777000000000777077700007770777777700007770000777077700007770777000777700000
77700000000777000077707770007770007770777777700000000777000000000777077700007770777777700007770000777077700007770777000077700000
77700007770777000077707770007770007770777777700000000777000000000777077700077770777777700007770007770077700007770777000077700000
77770007770777000077707770007770007770777000000000000777700000007777077700077700777000000007777777770077700007770777000077700000
07770007770777777777707770007770007770777000000000000077700000007770077700777700777000000007777777700077700077700777000077700000
07777707770777777777707770007770007770777000000000000077777000777770077707777000777000000007777777770077700777700777000077700000
00777777770777777777707770007770007770777777777700000007777777777700077777770000777777777707770007770077777777000777000077700000
00077777770777000077707770007770007770777777777700000000777777777000077777700000777777777707770000777077777770000777000077700000
00000777770777000077707770007770007770777777777700000000007777700000077770000000777777777707770000777077777000000777000077700000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
aaaaaaaa000aaaa00000000000000aaaaaaa000000000000000000000000aa008888800000000088880000888888880000088000008808800000088000000000
aaaaaaaa00aa00aa00000000000000aaaa0aaa00000000000000000000aaaa008888888000008888888800888888880000088000008808800000088000000000
aaaaaaaa0aaa00aaa0000000000000aaa000aaa00000000000000000000aaa008800888800008800008800880000000000088000008808800000088000000000
a00000a00aa0000aa0000000000000aaa0000aaa0000000000000000000aaa008800008880088000000880880000000000888800008808800000088000000000
00000aa0aaa0000aaa000000000000aaa0000aaa0000000000000000000aaa008800000880088000000880880000000000888800008800880000880000000000
00000a00aaa0000aaa000aaaa0aa00aaa0000aaaa000aaaaaa00000aaa0aaa008800000888088000000880880000000000888800008800880000880000000000
0000aa00aaa0000aaa00aa000aaa00aaa0000aaaa00aa00aaaa000aaa0aaaa008800000088088000000880880000000008800880008800880000880000000000
0000aa00aaa0000aaa0aaa0000aa00aaa0000aaaa0aaaa00aaa000aa000aaa008800000088088800008800888888880008800880008800088008800000000000
000aa000aaa0000aaa0aaaa0000a00aaa0000aaaa00aa000aaa00aaa000aaa008800000088088888888800888888880008800880008800088008800000000000
000aa000aaa0000aaa0aaaaaa00000aaa0000aaaa0000aaaaaa00aaa000aaa008800000088088888880000880000000088000088008800088008800000000000
00aaa000aaa0000aaa00aaaaaaa000aaa0000aaaa00aaa00aaa00aaa000aaa008800000888088888000000880000000088000088008800008888000000000000
00aaa000aaa0000aaa0000aaaaaa00aaa0000aaa00aaa000aaa00aaa000aaa008800000880088088800000880000000088888888008800008888000000000000
00aa00000aa0000aa00a0000aaaa00aaa0000aaa00aaa000aaa00aaa000aaa008800008880088008880000880000000888888888808800008888000000000000
0aaa00000aaa00aaa00aa0000aaa00aaa000aaa000aaa000aaa00aaa000aaa008800888800088000888000880000000880000008808800000880000000000000
0aaa000000aa00aa000aaa000aa000aaaa0aaa00000aaa0aaaa0a0aaa0aaaaa08888888000088000088800888888880880000008808800000880000000000000
0aaa0000000aaaa0000aa0aaaa000aaaaaaa00000000aaa00aaa000aaa0aa0008888800000088000008880888888880880000008808800000880000000000000
444444444444444444444444444444404444008888000008888000880880008808888808880000008800000000000f99999990000f9900000000000000000000
499999949949994994994499999499404994008888880088888800880880008808888808880000008800000000000f9999999000f92990000000000000000000
499999949949999994994999999499404994008800880088000880880088088008800008088000088000000000000f222222900f920299000000000000000000
4994444499499999949949994444994449940088000880880008808800880880088000080880000880000000000002000000900f900099000f99909000000000
499994a49949949994994499944499999994008800088088800880880088088008888808008800880000000000000000000920f990009990f992299000000000
499994449949949994994449994499999994008800088088888800880008880008888808008800880000000000000000009200f99000f990f9900f9000000000
499444e49949944994994444999499444994008800088088888000880008880008800000000888800000000000000000092000f99000f9902999029000000000
4994a44499499449949949999994994a4994008800880088088000880008880008800000000888800000000000000000990000f9900099900299902000000000
49944404994994499499499999449944499400888888008800880088000080000888880800008800000000000000000f920000299000f920902f990000000000
4444e40444444444444444444444444e444400888800008800088088000080000888880800008800000000000000000990000009900092009f02999000000000
4aa44404aa4aa44aa4aa4aaaaa44aa444aa40000000000000000000000000000000000000000880000000000000000f990000002990f90009900f99000000000
4444000444444444444444444444444044440000000000000000000000000000000000000000880000000000000000f990000000299920009299992000000000
4ee40004ee4ee44ee4ee4eeeee44ee404ee400000000000000000000000000000000000000008800000000000000002220000000022200002022220000000000
44440004444444444444444444444440444400000000000000000000000000000000000000008800000000000000000000000000000000000000000000000000
000000000000000000000000000000000000000000000000000000000000000000000000000088000000000000000f9999900000000000000009000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000880000000000000002f922f90000000000000f99000000000000
0077770000777000007777000077770000007770077777700000777007777770000770000077770000000000000000f900299000000000000099000000000000
0777777000777000077777700777777000077770077777700007770007777770007777000777777000000000000000f9000f90099990000990f9000000000000
0770077000077000077007700770077000777770077000000077700000000770007007000770077000000000000000f9000f90f22299009229f9000000000000
077007700007700000007770000077d007770770077777000777770000007770007dd700077d077000000000000000f9000f90f900f90f900299000000000000
077007700007700000077700000077d0077007700770d7700770d77000077700077777700077777000000000000000f9000990f900f90f900099000000000000
0770077000077000007770000770077007777777000007700770077000777000077007700007770000000000000000f9000f902299990f9000f9000000000000
0777777000077000077777700777777007777777077777700777777007770000077dd7700077700000000000000000f90009900922990f9000f9000000000000
0077770000077000077777700077770000000770007777000077770007700000007777000777000000000000000000f9000990f900f90f900099000000000000
7770000777077777007700007700000000777700000000000000000000000000000000000000000000000000000000f900f920f909990f900999000000000000
777700777707777770770000770000000700007000000000000000000000000000000000000000000000000000000f999992002f922992f99299900000000000
77770077770770077077000077000000705008070000000000000000000000000000000000000000000000000000022222200002200220222022200000000000
77077770770770077077777777000000700080070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
77077770770777777077777777000000700000070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
77007700770777770077000077000000705000570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
77007700770770000077000077000000070000700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
77007700770770000077000077000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__label__
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
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000088800000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000880880000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000008800088000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000088000008800000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000880000000880000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000008800000000088000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000aaaaaaaa000aaaa000000000008800000aaaaaaa800000000000000000000000aa0000000000000000000000000000000
0000000000000000000000000000000aaaaaaaa00aa00aa000000000880000000aaaa0aaa00000000000000000000aaaa0000000000000000000000000000000
0000000000000000000000000000000aaaaaaaa0aaa00aaa00000008800000000aaa000aaa00000000000000000000aaa0000000000000000000000000000000
0000000000000000000000000000000a00000a00aa0000aa00000088000000000aaa0000aaa0000000000000000000aaa0000000000000000000000000000000
000000000000000000000000000000000000aa0aaa0000aaa0000880000000000aaa0000aaa8000000000000000000aaa0000000000000000000000000000000
000000000000000000000000000000000000a00aaa0000aaa000aaaa0aa000000aaa0000aaaa800aaaaaa00000aaa0aaa0000000000000000000000000000000
00000000000000000000000000000000000aa00aaa0000aaa00aa000aaa000000aaa0000aaaa88aa00aaaa000aaa0aaaa0000000000000000000000000000000
00000000000000000000000000000000000aa00aaa0000aaa0aaa0000aa000000aaa0000aaaa0aaaa00aaa000aa000aaa0000000000000000000000000000000
0000000000000000000000000000000000aa000aaa0000aaa8aaaa0000a000000aaa0000aaaa00aa000aaa00aaa000aaa0000000000000000000000000000000
0000000000000000000000000000000000aa000aaa0000aaa8aaaaaa000000000aaa0000aaaa0008aaaaaa00aaa000aaa0000000000000000000000000000000
000000000000000000000000000000000aaa000aaa0000aaa00aaaaaaa0000000aaa0000aaaa00aaa80aaa00aaa000aaa0000000000000000000000000000000
000000000000000000000000000000000aaa000aaa0000aaa0000aaaaaa000000aaa0000aaa00aaa088aaa00aaa000aaa0000000000000000000000000000000
000000000000000000000000000000000aa00000aa0008aa00a0000aaaa000000aaa0000aaa00aaa008aaa00aaa000aaa0000000000000000000000000000000
00000000000000000000000000000000aaa00000aaa08aaa00aa0000aaa000000aaa000aaa000aaa000aaa00aaa000aaa0000000000000000000000000000000
00000000000000000000000000000000aaa000000aa88aa000aaa000aa0000000aaaa0aaa00000aaa0aaaa0a0aaa0aaaa0000000000000000000000000000000
00000000000000000000000000000000aaa0000000aaaa0000aa0aaaa0000000aaaaaaa00000000aaa00aaa000aaa0aa00000000000000000000000000000000
00000000000000000000000000000000000000000880000000000000000000000000000000000000000000880000000000000000000000000000000000000000
00000000000000000000000000000000000000008800000000000000000000000000000000000000000000088000000000000000000000000000000000000000
00000000000000000000000000000009999900088000099999900000000999000099900009990000999000099900009990990000000000000000000000000000
00000000000000000000000000000009999999880000099999999000000999000099900009990000999000099999009990990000000000000000000000000000
00000000000000000000000000000009999999900000099999999900000999000099900009990000999000099999909990990000000000000000000000000000
00000000000000000000000000000009990099990000099900099900000999000099900009990000999000099999999990000000000000000000000000000000
00000000000000000000000000000009990889990000099900009990000999000099900009990000999000099900999990000000000000000000000000000000
00000000000000000000000000000009998800999000099900009990000999000099900009990000999000099900099990000000000000000000000000000000
00000000000000000000000000000009998000999000099900009990000999000099900009990000999000099900099990000000000000000000000000000000
00000000000000000000000000000009990000999000099900009990000999000099900009990000999000099900009990000000000000000000000000000000
00000000000000000000000000000009990000999000099900099900000999000099900099990000999000099900009998000000000000000000000000000000
00000000000000000000000000000089990000999000099999999900000999000099900099900000999000099900009998800000000000000000000000000000
00000000000000000000000000000889990009990000099999999000000999000099900999900000999000099900009990880000000000000000000000000000
00000000000000000000000000008809990099990000099999999900000999000099909999000000999000099900009990088000000000000000000000000000
00000000000000000000000000088009999999900000099900099900000999000099999990000000999000099900009990008800000000000000000000000000
00000000000000000000000000880009999999000000099900009990000999000099999900000000999000099900009990000880000000000000000000000000
00000000000000000000000008800009999900000000099900009990000999000099990000000000999000099900009990000088000000000000000000000000
00000000000000000000000088000000000000000000000000000000000000000000000000000000000000000000000000000008800000000000000000000000
00000000000000000000000880000000000000000000000000000000000000000000000000000000000000000000000000000000880000000000000000000000
00000000000000000000008800000000000000000000000000000000000000000000000000000000000000000000000000000000088000000000000000000000
00000000000000000000088000000000000000000000000000000000000000000000000000000000000000000000000000000000008800000000000000000000
00000000000000000000880000000000000000000000000000000000000000000000000000000000000000000000000000000000000880000000000000000000
00000000000000000008800000000000000000000000000000000000000000000000000000000000000000000000000000000000000088000000000000000000
00000000000000000088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008800000000000000000
00000000000000000880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000880000000000000000
00000000000000008800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088000000000000000
00000000000000088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008800000000000000
00000000000000880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000880000000000000
00000000000008800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088000000000000
00000000000088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008800000000000
00000000000880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000880000000000
00000000008800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088000000000
00000000088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008800000000
00000000880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000880000000
00000008800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088000000
00000088000000000000000000000004444444444444444444440004444400044444444400004444444444444444444400000000000000000000000008800000
00000880000000000000000000000004999499949994499449940004999400049994499400044994999499949994999400000000000000000000000000880000
00008800000000000000000000000004949494949444944494440004449400044944949400049444494494949494494400000000000000000000000000088000
00088000000000000000000000000004999499449944999499940004494400024944949400049994494499949944494000000000000000000000000000008800
00880000000000000000000000000004944494949444449444940004944400004944949400044494494494949494494000000000000000000000000000000880
08800000000000000000000000000004942494949994994499440004999400004944994400049944494494949494494000000000000000000000000000000088
88000000000000000000000000000004440444444444444444400004444400004444444000044440444444444444444000000000000000000000000000000008
80000000000000000000000000000002200222222222220222000002222000002202220000022200220222222220220000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000004444444400004444444444444444444044444444444444444444400044444444000044444444444444444444400000000000000000000
00000000000000000004999449400004999499949994999494049994999499949994999400049494494000049944999499949494999400000000000000000000
00000000000000000004449444400004949494449444994494049944949494944944994400044944444000049944949494949944994400000000000000000000
00000000000000000004944449400004999494449444944494449444994499944944944400049494494000049494994499949494944400000000000000000000
00000000000000000004999444400004949499949994999499949994949494944944999400049494444000049994949494949494999400000000000000000000
00000000000000000004444422000004444444444444444444444444444444444444444400044444220000044444444444444444444400000000000000000000
00000000000000000002222000000002222222222222222222222222222222202202222000022220000000022222222222222222222000000000000000000000
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

__gff__
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__map__
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
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
010200020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
011000000c04310000246250e0000c04310000110000c0430c0430c0000c0000c0000c04310000246250c0000c04310000246250e0000c04310000110000c0430c0430c0000c0000c0000c04310000246250c000
01100000021450e101021450214502145021450214502145021450214502145021450214502145021450914000145001000014500145001450014500145001450014500145001450014500145001450014507140
011000001a4351a4251a4051c4351c4251c415004051d4211d4351d4251d4051f4351f4251f41100405214212143521425214052143521425214112140521425214352142500405214352142521415004051a425
01100000266501f6430e6251f60016600136001360014600166001c600216001d6001d60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
012600000c0430c0030c033246250c0030c0330c0430c0000c033246250c0330c0330c043246050c033246250c0000c0330c043246000c033246250c0330c0330c0430c0000c043246250c0000c0330c04300000
012600003c7353c7253c7153c7253c7153c7153c7353c7253c7153c7253c7153c7153c7353c7253c7153c7253c7153c7153c7353c7253c7153c7253c7153c7150070500705007050070500705007050070500705
011300000414004145100001000004145100050414510005041450000004145000000413004135091350b1250e135101250e1320e1220e1120e11500000000000000000000000000000000000000000000000000
0113000023230252112623023225002001f230212251c2021c2321c2221c2221c2121c215000001c2351e22521235232252123221222212122121500000000000000000000000000000000000000000000000000
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
03 05060708
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

