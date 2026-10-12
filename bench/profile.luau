--!native
local scene=require('@dream/scene')
local mode=arg[1] or 'dirtyroot'
local n=tonumber(arg[2]) or 100000
local iterations=tonumber(arg[3]) or 100
local s=scene.new(n)
s:beginBatch()
local roots={}
local groups=math.max(1,math.floor(n/64))
for g=1,groups do local h=s:create(); roots[g]=h; s:setPosition(h,(g%64)*128,math.floor(g/64)*128,0) end
local handles={}
for i=1,n-groups do
    local h=s:create(roots[((i-1)%groups)+1]); handles[i]=h
    s:setPosition(h,(i%16)*4,(math.floor(i/16)%16)*4,(i%7)*0.5)
    s:setBounds(h,-1,-1,-1,1,1,1)
    if i%4==0 then s:setRange(h,0,512) end
end
s:endBatch(); s:update()
local out={}
if mode=='idle' then
    for _=1,iterations do s:update() end
elseif mode=='dirtyleaf' then
    for i=1,iterations do local h=handles[((i-1)%#handles)+1]; local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.01,y,z); s:update() end
elseif mode=='dirtyroot' then
    for i=1,iterations do local h=roots[((i-1)%#roots)+1]; local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.01,y,z); s:update() end
elseif mode=='dirty1pct' then
    local count=math.max(1,math.floor(#handles/100))
    for r=1,iterations do
        for i=1,count do local h=handles[((i*97+r-2)%#handles)+1]; local x,y,z=s:getWorldPosition(h); s:setPosition(h,x+0.001,y,z) end
        s:update()
    end
elseif mode=='collect' then
    for _=1,iterations do s:collect(0xffffffff,out) end
elseif mode=='query-small' then
    for _=1,iterations do s:queryAabb(0,0,-10,64,64,10,0xffffffff,out) end
elseif mode=='query-world' then
    for _=1,iterations do s:queryAabb(-100000,-100000,-100000,100000,100000,100000,0xffffffff,out) end
elseif mode=='view' then
    for _=1,iterations do s:collectForView(0,0,0,0xffffffff,out) end
elseif mode=='churn' then
    for i=1,iterations do local h=s:create(roots[((i-1)%#roots)+1]); s:destroy(h) end
    s:update()
else error('unknown mode') end
print(mode,n,iterations,#out,s:stats().nodes)
