-- Register the installed app without modifying its bundle or signing identity.
set appPath to (POSIX path of (path to home folder)) & "Applications/GigaFlow.app"
tell application "System Events"
    if not (exists disk item appPath) and (exists disk item "/Applications/GigaFlow.app") then
        set appPath to "/Applications/GigaFlow.app"
    end if
    if not (exists disk item appPath) then error "Installed GigaFlow.app was not found"
    set matchingItems to every login item whose path is appPath
    if (count of matchingItems) is 0 then
        make new login item at end with properties {name:"GigaFlow", path:appPath, hidden:true}
    end if
    set matchingItems to every login item whose path is appPath
    if (count of matchingItems) is not 1 then error "Unexpected number of GigaFlow login items"
    return {name, path, hidden} of item 1 of matchingItems
end tell
