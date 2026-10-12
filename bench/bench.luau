--!native
local scene = require('@dream/scene')

local function median(values)
    table.sort(values)
    local n=#values
    if n%2==1 then return values[(n+1)//2] end
    return (values[n//2]+values[n//2+1])*0.5
end

local function measure(rounds,fn)
    local samples=table.create(rounds)
    for r=1,rounds do local t=os.clock(); fn(); samples[r]=(os.clock()-t)*1000 end
    return median(samples)
end

local function populate(n,batch)
    local s=scene.new(n)
    if batch then s:beginBatch() end
    local groups=math.max(1,math.floor(n/64))
    local roots=table.create(groups)
    local leaves=table.create(n-groups)
    for g=1,groups do
        local h=s:create(); roots[g]=h
        s:setPosition(h,(g%64)*128,math.floor(g/64)*128,0)
    end
    for i=1,n-groups do
        local h=s:create(roots[((i-1)%groups)+1]); leaves[i]=h
        s:setPosition(h,(i%16)*4,(math.floor(i/16)%16)*4,(i%7)*0.5)
        s:setBounds(h,-1,-1,-1,1,1,1)
        if i%4==0 then s:setRange(h,0,512) end
    end
    if batch then s:endBatch() end
    s:update()
    return s,leaves,roots
end

local sizes={1000,10000,100000,250000}
local rounds=7
print('n,packed_mib,build_incremental_ms,build_batch_ms,idle_update_ms,dirty_leaf_ms,dirty_root64_ms,dirty_1pct_ms,collect_all_ms,query_small_ms,query_world_ms,view_collect_ms,churn_1000_ms')
for _,n in sizes do
    local incTimes={}
    local batchTimes={}
    local s,leaves,roots
    for r=1,3 do local t=os.clock(); populate(n,false); incTimes[r]=(os.clock()-t)*1000 end
    for r=1,3 do local t=os.clock(); s,leaves,roots=populate(n,true); batchTimes[r]=(os.clock()-t)*1000 end
    local stats=s:stats()
    local out={}
    local idle=measure(rounds,function() s:update() end)
    local leafIndex=1
    local dirtyLeaf=measure(rounds,function()
        local h=leaves[leafIndex]; leafIndex=(leafIndex%#leaves)+1
        local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.01,y,z); s:update()
    end)
    local rootIndex=1
    local dirtyRoot=measure(rounds,function()
        local h=roots[rootIndex]; rootIndex=(rootIndex%#roots)+1
        local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.01,y,z); s:update()
    end)
    local onePct=math.max(1,math.floor(#leaves/100))
    local dirty1pct=measure(5,function()
        for i=1,onePct do
            local h=leaves[((i*97-1)%#leaves)+1]
            local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.001,y,z)
        end
        s:update()
    end)
    local collectAll=measure(rounds,function() s:collect(0xffffffff,out) end)
    local querySmall=measure(rounds,function() s:queryAabb(0,0,-10,64,64,10,0xffffffff,out) end)
    local queryWorld=measure(rounds,function() s:queryAabb(-100000,-100000,-100000,100000,100000,100000,0xffffffff,out) end)
    local viewCollect=measure(rounds,function() s:collectForView(0,0,0,0xffffffff,out) end)
    local churn=measure(5,function()
        for i=1,1000 do local h=s:create(roots[((i-1)%#roots)+1]); s:destroy(h) end
        s:update()
    end)
    print(`{n},{stats.packedBytes/1048576},{median(incTimes)},{median(batchTimes)},{idle},{dirtyLeaf},{dirtyRoot},{dirty1pct},{collectAll},{querySmall},{queryWorld},{viewCollect},{churn}`)
end
