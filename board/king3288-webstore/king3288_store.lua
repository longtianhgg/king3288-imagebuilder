module("luci.controller.king3288_store", package.seeall)

-- KING3288: browse the signed OPKG feeds already verified on the running SD.
-- Do not silently accept packages from arbitrary, user-provided file paths.
local FEEDS = { "king3288_m8", "openwrt_base" }
local PAGE_SIZE = 30
local ARCH = "arm_cortex-a15_neon-vfpv4"
local REPORT = "/tmp/king3288-store-install.log"

local PROTECTED = {
    ["base-files"]=true, ["busybox"]=true, ["dnsmasq"]=true,
    ["dnsmasq-full"]=true, ["dropbear"]=true, ["firewall4"]=true,
    ["fstools"]=true, ["fwtool"]=true, ["kernel"]=true, ["libc"]=true,
    ["logd"]=true, ["netifd"]=true, ["opkg"]=true, ["procd"]=true,
    ["procd-seccomp"]=true, ["procd-ujail"]=true, ["ubox"]=true,
    ["ubus"]=true, ["ubusd"]=true, ["uci"]=true, ["uhttpd"]=true,
    ["uboot-envtools"]=true, ["block-mount"]=true, ["mtd"]=true
}

local CATEGORIES = {
    { id="all", title="全部" },
    { id="tools", title="工具" },
    { id="network", title="网络" },
    { id="luci", title="LuCI 插件" },
    { id="system", title="系统" },
    { id="other", title="其他" }
}

local function valid_name(name)
    return type(name) == "string"
        and #name <= 100
        and name:match("^[%w][%w_.+%-]*$") ~= nil
end

local function category_of(name, section)
    section = (section or ""):lower()
    if name:match("^luci%-") then return "luci" end
    if section:find("net", 1, true) or section:find("vpn", 1, true) then return "network" end
    if section:find("util", 1, true) or section:find("admin", 1, true) then return "tools" end
    if section:find("base", 1, true) or section:find("system", 1, true)
        or section:find("firmware", 1, true) then return "system" end
    return "other"
end

local function is_safe_to_offer(name)
    if not valid_name(name) or PROTECTED[name] then return false end
    if name:match("^kmod%-") or name:match("^lib") then return false end
    if name:match("^uboot") or name:match("^u%-boot") then return false end
    if name:match("%-firmware$") or name:match("^firmware") then return false end
    return true
end

local function installed_set()
    local installed = {}
    local pipe = io.popen("opkg list-installed 2>/dev/null", "r")
    if pipe then
        for line in pipe:lines() do
            local name = line:match("^([^ ]+) %- ")
            if name then installed[name] = true end
        end
        pipe:close()
    end
    return installed
end

local function package_catalog()
    local catalog = {}
    -- Both file names below are fixed; no request parameter reaches this command.
    for _, feed in ipairs(FEEDS) do
        local path = "/var/opkg-lists/" .. feed
        local fd = io.open(path, "rb")
        if fd then
            fd:close()
            local pipe = io.popen("gzip -dc " .. path .. " 2>/dev/null", "r")
            if pipe then
                local stanza = {}
                local function commit()
                    local name = stanza.Package
                    local arch = stanza.Architecture
                    if valid_name(name) and not catalog[name]
                        and (arch == ARCH or arch == "all" or arch == "noarch") then
                        catalog[name] = {
                            name = name,
                            version = stanza.Version or "",
                            desc = (stanza.Description or ""):sub(1, 240),
                            section = stanza.Section or "",
                            source = feed,
                            category = category_of(name, stanza.Section),
                            can_install = is_safe_to_offer(name)
                        }
                    end
                    stanza = {}
                end
                for line in pipe:lines() do
                    if line == "" then
                        commit()
                    else
                        local key, value = line:match("^([%w%-]+):%s*(.*)$")
                        if key and (key == "Package" or key == "Version"
                            or key == "Architecture" or key == "Section"
                            or key == "Description") then
                            stanza[key] = value
                        end
                    end
                end
                commit()
                pipe:close()
            end
        end
    end
    return catalog
end

function index()
    entry({"admin", "store", "king3288"}, call("show_store"), _("KING3288 ARMv7 软件"), 5)
    entry({"admin", "store", "king3288-install"}, post("install_package")).leaf = true
end

function show_store()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    local query = (http.formvalue("q") or ""):sub(1, 80)
    local category = http.formvalue("category") or "all"
    local valid_category = false
    for _, item in ipairs(CATEGORIES) do
        if item.id == category then valid_category = true end
    end
    if not valid_category then category = "all" end

    local installed = installed_set()
    local catalog = package_catalog()
    local found = {}
    local count = 0
    local query_lower = query:lower()
    for _, pkg in pairs(catalog) do
        count = count + 1
        pkg.installed = installed[pkg.name] == true
        if (category == "all" or pkg.category == category)
            and (query == ""
                or pkg.name:lower():find(query_lower, 1, true)
                or pkg.desc:lower():find(query_lower, 1, true)) then
            found[#found + 1] = pkg
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)

    local pages = math.max(1, math.ceil(#found / PAGE_SIZE))
    local page = math.floor(tonumber(http.formvalue("page")) or 1)
    page = math.min(math.max(1, page), pages)
    local selected = {}
    for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #found) do
        selected[#selected + 1] = found[i]
    end

    require("luci.template").render("king3288/store", {
        apps = selected, categories = CATEGORIES, query = query,
        category = category, page = page, pages = pages,
        matched = #found, total = count, report = fs.readfile(REPORT) or ""
    })
end

function install_package()
    local http = require "luci.http"
    local dispatcher = require "luci.dispatcher"
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local util = require "luci.util"
    local name = http.formvalue("package")

    -- Re-check live trusted feed membership on every POST, not only on GET.
    local catalog = package_catalog()
    if not valid_name(name) or not catalog[name] or not catalog[name].can_install then
        http.status(400, "Package not available for safe installation")
        return
    end
    if installed_set()[name] then
        fs.writefile(REPORT, name .. " 已安装，不执行升级。\n")
    else
        local cmd = "opkg install " .. util.shellquote(name)
            .. " 2>&1; echo KING3288_INSTALL_RC=$?"
        local result = sys.exec(cmd) or ""
        fs.writefile(REPORT, result:sub(1, 16000))
    end
    http.redirect(dispatcher.build_url("admin", "store", "king3288"))
end
