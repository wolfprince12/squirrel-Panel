display dialog "即将移除 Squirrel Panel.app 的隔离属性，使其可以正常打开。" buttons {"取消", "修复"} default button "修复" with icon caution
if button returned of result is "修复" then
	do shell script "xattr -cr '/Applications/Squirrel Panel.app'"
	display dialog "已修复。你现在可以从 Applications 文件夹正常启动 Squirrel Panel。" buttons {"确定"} default button "确定"
end if
