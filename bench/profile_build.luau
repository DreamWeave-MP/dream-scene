--!native
local scene=require('@dream/scene')
local n=tonumber(arg[1]) or 100000
local batch=(arg[2] or 'batch')=='batch'
local s=scene.new(n)
if batch then s:beginBatch() end
local roots={}
local groups=math.max(1,math.floor(n/64))
for g=1,groups do local h=s:create(); roots[g]=h; s:setPosition(h,(g%64)*128,math.floor(g/64)*128,0) end
for i=1,n-groups do
    local h=s:create(roots[((i-1)%groups)+1])
    s:setPosition(h,(i%16)*4,(math.floor(i/16)%16)*4,(i%7)*0.5)
    s:setBounds(h,-1,-1,-1,1,1,1)
end
if batch then s:endBatch() end
local u=s:update()
print('build',n,batch,u.transformsUpdated,u.boundsUpdated,s:stats().packedBytes)
