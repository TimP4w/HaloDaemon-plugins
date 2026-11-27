-- SPDX-License-Identifier: GPL-3.0-or-later
local M={}
function M.clip(x,y,gamut)
  if not gamut or not gamut.red or not gamut.green or not gamut.blue then return x,y end
  local points={gamut.red,gamut.green,gamut.blue}
  local positive,negative=false,false
  local best_x,best_y,best_distance=x,y,math.huge
  for i=1,3 do
    local a,b=points[i],points[i%3+1]
    local dx,dy=b.x-a.x,b.y-a.y
    local cross=dx*(y-a.y)-dy*(x-a.x)
    positive=positive or cross>0; negative=negative or cross<0
    local length=dx*dx+dy*dy
    local t=length>0 and math.max(0,math.min(1,((x-a.x)*dx+(y-a.y)*dy)/length)) or 0
    local px,py=a.x+t*dx,a.y+t*dy
    local distance=(x-px)^2+(y-py)^2
    if distance<best_distance then best_x,best_y,best_distance=px,py,distance end
  end
  if positive and negative then return best_x,best_y end
  return x,y
end
return M
