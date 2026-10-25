-- SPDX-License-Identifier: GPL-3.0-or-later
return {value=function(snapshot)
  if snapshot.status=="fresh" then return snapshot.value end
  return nil
end}
