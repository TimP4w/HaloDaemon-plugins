local telemetry=halod.require("lib.telemetry")
return function(h)
  halod.monotonic_ms=function() return 0 end
  h:assert_eq(telemetry.rpm(true,4,176),1200,"legacy tachometer is already RPM")
  h:assert_eq(telemetry.rpm(true,255,255),0,"legacy sentinel is absent")
  h:assert_eq(telemetry.rpm(false,28,4),1500,"period tachometer converts count to RPM")
  local writes={}
  local io={lpcio_read_port=function(_,port) return port==0x604 and 255 or 42 end,
    lpcio_write_port=function(_,port,value) writes[#writes+1]={port,value} end}
  h:assert_eq(telemetry.ec_read(io,0x600,0x1234),42,"EC reads the data window")
  h:assert_eq(writes,{{0x604,0x12},{0x605,0x34},{0x604,255}},"EC selects page/index and releases ownership")
  io.lpcio_read_port=function(_,port) if port==0x606 then error("read failed") end return 255 end
  h:assert(not pcall(function() telemetry.ec_read(io,0x600,0x1234) end),"EC read failures propagate")
  h:assert_eq(writes[#writes],{0x604,255},"EC ownership is released after a failed read")
  local time=0
  halod.monotonic_ms=function() time=time+250; return time end
  halod.sleep_ms=function() end
  io.lpcio_read_port=function() return 0 end
  local count=#writes
  h:assert(not pcall(function() telemetry.ec_read(io,0x600,0x1234) end),"busy EC window times out")
  h:assert_eq(#writes,count,"busy ownership is never stolen")

end
