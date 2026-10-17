module("luci.controller.king3288_store", package.seeall)

-- KING3288 ARMv7 curated packages, served by already trusted OPKG feeds.
-- Only these exact names can be installed using this controller.
local catalog = {
    { name = "more", title = "more 文件查看器", desc = "分页查看文本文件，轻量且不修改网络配置" },
    { name = "strace", title = "strace 进程跟踪", desc = "跟踪程序系统调用，辅助问题定位" },
    { name = "tcpdump", title = "tcpdump 网络抓包", desc = "命令行抓包工具，不改变网络配置" },
    { name = "badblocks", title = "badblocks 存储检测", desc = "提供磁盘检测命令；只安装工具，不会自动扫描" },
    { name = "cal", title = "cal 日历", desc = "显示日历（可用于已安装状态验证）" }
}

local function is_allowed(name)
    for _, entry in ipairs(catalog) do
        if entry.name == name then return true end
    end
    return false
end

local function installed_set()
    local sys = require "luci.sys"
    local installed = {}
    for line in (sys.exec("opkg list-installed 2>/dev/null") or ""):gmatch("[^\r\n]+") do
        local name = line:match("^([^ ]+) %- ")
        if name then installed[name] = true end
    end
    return installed
end

function index()
    entry({"admin", "store", "king3288"}, call("show_store"), _("KING3288 ARMv7 软件"), 5)
    entry({"admin", "store", "king3288-install"}, post("install_package")).leaf = true
end

function show_store()
    local fs = require "nixio.fs"
    local data = {}
    local installed = installed_set()
    for _, app in ipairs(catalog) do
        data[#data + 1] = {
            name = app.name, title = app.title, desc = app.desc,
            installed = installed[app.name] == true
        }
    end
    local report = fs.readfile("/tmp/king3288-store-install.log") or ""
    require("luci.template").render("king3288/store", { apps = data, report = report })
end

function install_package()
    local http = require "luci.http"
    local dispatcher = require "luci.dispatcher"
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local name = http.formvalue("package")
    if not name or not is_allowed(name) then
        http.status(400, "Invalid or unsupported package")
        return
    end
    if installed_set()[name] then
        fs.writefile("/tmp/king3288-store-install.log", name .. " 已安装，不执行升级。\n")
    else
        local cmd = "opkg install " .. name .. " 2>&1; echo KING3288_INSTALL_RC=$?"
        local result = sys.exec(cmd) or ""
        fs.writefile("/tmp/king3288-store-install.log", result:sub(1, 16000))
    end
    http.redirect(dispatcher.build_url("admin", "store", "king3288"))
end
