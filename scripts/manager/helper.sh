#
# Log Definitions
#
export LINE='\n'
export RESET='\033[0m'       # Text Reset
export WhiteText='\033[0;37m'        # White

# Bold
export RedBoldText='\033[1;31m'         # Red
export GreenBoldText='\033[1;32m'       # Green
export YellowBoldText='\033[1;33m'      # Yellow
export CyanBoldText='\033[1;36m'        # Cyan

LogInfo() {
    Log "$1" "$WhiteText"
}
LogWarn() {
    Log "$1" "$YellowBoldText"
}
LogError() {
    Log "$1" "$RedBoldText"
}
LogSuccess() {
    Log "$1" "$GreenBoldText"
}
LogAction() {
    Log "$1" "$CyanBoldText" "<------- " " ------->"
}
Log() {
    local message="$1"
    local color="$2"
    local prefix="$3"
    local suffix="$4"
    printf "$color%s$RESET$LINE" "$prefix$message$suffix"
}

# Send Discord Message
# Level is optional variable defaulting to info
DiscordMessage() {
    local title="$1"
    local message="$2"
    local level="$3"
    local enabled="$4"
    local webhook_url="$5"
    if [ -z "$level" ]; then
        level="info"
    fi
    if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
        /opt/manager/discord.sh "$title" "$message" "$level" "$enabled" "$webhook_url" &
    fi
}

SelectArchive() {
    set -e
    path=$1
    select fname in $path/*; do
        echo $fname
        break;
    done
    if [[ $REPLY == "" ]]; then
        LogError "Invalid input. Please enter a valid number."
        return 1
    fi
    return 0
}
