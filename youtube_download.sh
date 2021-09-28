#!/bin/sh

# 初始化全局变量
URL_YOUTUBE=$(echo -e "$1")
if [[ -z $2 ]]; then DL_FOLDER=`pwd`; else DL_FOLDER="$2"; fi
PROXY_ENABLED=no
PROXY='socks5h://127.0.0.1:24456'


TEMP_DIR='/tmp/tmp_youtube'
RAW_PAGE="${TEMP_DIR}/youtube_raw_page.html"
YOUTUBE_JSON="${TEMP_DIR}/youtube.json"


function json_parse_env() {
    BRIEF=0
    LEAFONLY=0
    PRUNE=0
    NO_HEAD=0
    NORMALIZE_SOLIDUS=0
}

function json_throw() {
  echo "$*" >&2
  exit 1
}

function json_parse_usage() {
    echo
    echo "Usage: JSON.sh [-b] [-l] [-p] [-s] [-h]"
    echo
    echo "-p - Prune empty. Exclude fields with empty values."
    echo "-l - Leaf only. Only show leaf nodes, which stops data duplication."
    echo "-b - Brief. Combines 'Leaf only' and 'Prune empty' options."
    echo "-n - No-head. Do not show nodes that have no path (lines that start with [])."
    echo "-s - Remove escaping of the solidus symbol (straight slash)."
    echo "-h - This help text."
    echo
}

function json_parse_options() {
    set -- "$@"
    local ARGN=$#
    while [ "$ARGN" -ne 0 ]
    do
    case $1 in
        -h) json_parse_usage
            exit 0
        ;;
        -b) BRIEF=1
            LEAFONLY=1
            PRUNE=1
        ;;
        -l) LEAFONLY=1
        ;;
        -p) PRUNE=1
        ;;
        -n) NO_HEAD=1
        ;;
        -s) NORMALIZE_SOLIDUS=1
        ;;
        ?*) echo "ERROR: Unknown option."
            json_parse_usage
            exit 0
        ;;
    esac
    shift 1
    ARGN=$((ARGN-1))
    done
}

function json_awk_egrep () {
    local pattern_string=$1

    gawk '{
    while ($0) {
        start=match($0, pattern);
        token=substr($0, start, RLENGTH);
        print token;
        $0=substr($0, start+RLENGTH);
    }
    }' pattern="$pattern_string"
}

function json_tokenize () {
    local GREP
    local ESCAPE
    local CHAR

    if echo "test string" | egrep -ao --color=never "test" >/dev/null 2>&1
    then
    GREP='egrep -ao --color=never'
    else
    GREP='egrep -ao'
    fi

    if echo "test string" | egrep -o "test" >/dev/null 2>&1
    then
    ESCAPE='(\\[^u[:cntrl:]]|\\u[0-9a-fA-F]{4})'
    CHAR='[^[:cntrl:]"\\]'
    else
    GREP=json_awk_egrep
    ESCAPE='(\\\\[^u[:cntrl:]]|\\u[0-9a-fA-F]{4})'
    CHAR='[^[:cntrl:]"\\\\]'
    fi

    local STRING="\"$CHAR*($ESCAPE$CHAR*)*\""
    local NUMBER='-?(0|[1-9][0-9]*)([.][0-9]*)?([eE][+-]?[0-9]*)?'
    local KEYWORD='null|false|true'
    local SPACE='[[:space:]]+'

    # Force zsh to expand $A into multiple words
    local is_wordsplit_disabled=$(unsetopt 2>/dev/null | grep -c '^shwordsplit$')
    if [ $is_wordsplit_disabled != 0 ]; then setopt shwordsplit; fi
    $GREP "$STRING|$NUMBER|$KEYWORD|$SPACE|." | egrep -v "^$SPACE$"
    if [ $is_wordsplit_disabled != 0 ]; then unsetopt shwordsplit; fi
}

function json_parse_array () {
    local index=0
    local ary=''
    read -r token
    case "$token" in
    ']') ;;
    *)
        while :
        do
        json_parse_value "$1" "$index"
        index=$((index+1))
        ary="$ary""$value" 
        read -r token
        case "$token" in
            ']') break ;;
            ',') ary="$ary," ;;
            *) json_throw "EXPECTED , or ] GOT ${token:-EOF}" ;;
        esac
        read -r token
        done
        ;;
    esac
    [ "$BRIEF" -eq 0 ] && value=$(printf '[%s]' "$ary") || value=
    :
}

function json_parse_object () {
    local key
    local obj=''
    read -r token
    case "$token" in
    '}') ;;
    *)
        while :
        do
        case "$token" in
            '"'*'"') key=$token ;;
            *) json_throw "EXPECTED string GOT ${token:-EOF}" ;;
        esac
        read -r token
        case "$token" in
            ':') ;;
            *) json_throw "EXPECTED : GOT ${token:-EOF}" ;;
        esac
        read -r token
        json_parse_value "$1" "$key"
        obj="$obj$key:$value"        
        read -r token
        case "$token" in
            '}') break ;;
            ',') obj="$obj," ;;
            *) json_throw "EXPECTED , or } GOT ${token:-EOF}" ;;
        esac
        read -r token
        done
    ;;
    esac
    [ "$BRIEF" -eq 0 ] && value=$(printf '{%s}' "$obj") || value=
    :
}

function json_parse_value () {
    local jpath="${1:+$1,}$2" isleaf=0 isempty=0 print=0
    
    case "$token" in
    '{') json_parse_object "$jpath" ;;
    '[') json_parse_array  "$jpath" ;;
    # At this point, the only valid single-character tokens are digits.
    ''|[!0-9]) json_throw "EXPECTED value GOT ${token:-EOF}" ;;
    *) value=$token
        # if asked, replace solidus ("\/") in json strings with normalized value: "/"
        [ "$NORMALIZE_SOLIDUS" -eq 1 ] && value=$(echo "$value" | sed 's#\\/#/#g')
        isleaf=1
        [ "$value" = '""' ] && isempty=1
        ;;
    esac
    [ "$value" = '' ] && return
    [ "$NO_HEAD" -eq 1 ] && [ -z "$jpath" ] && return

    [ "$LEAFONLY" -eq 0 ] && [ "$PRUNE" -eq 0 ] && print=1
    [ "$LEAFONLY" -eq 1 ] && [ "$isleaf" -eq 1 ] && [ $PRUNE -eq 0 ] && print=1
    [ "$LEAFONLY" -eq 0 ] && [ "$PRUNE" -eq 1 ] && [ "$isempty" -eq 0 ] && print=1
    [ "$LEAFONLY" -eq 1 ] && [ "$isleaf" -eq 1 ] && \
    [ $PRUNE -eq 1 ] && [ $isempty -eq 0 ] && print=1
    [ "$print" -eq 1 ] && printf "[%s]\t%s\n" "$jpath" "$value"
    :
}

function json_parse() {
    read -r token
    json_parse_value
    read -r token
    case "$token" in
        '') ;;
        *) json_throw "EXPECTED EOF GOT $token" ;;
    esac
}

function json_main() {
    json_parse_env
    json_parse_options "$@"
    json_tokenize | json_parse
}


function get_json_from_file() {
	local SOURCE_FILE_NAME=$1
	local START_POSITION=$2
	local TEMP_DIR=${TEMP_DIR}
	local i=0
	local j=0
	local n=1

	# trim left from START_POSITION
	cat "${SOURCE_FILE_NAME}" | tr '\n|\r' ' ' | awk -F "${START_POSITION}" '{print $(NF)}' \
		| sed "s/^[ ][ ]*\|^[\t][\t]*//g" >"${TEMP_DIR}/source_trim_left.txt"

	# get END_POSITION
	while read -r -N 1 CHAR
	do
		if [[ ${CHAR} == '{' ]]; then
			let i++
		fi
		if [[ ${CHAR} == '}' ]]; then
			let j++
		fi

		if [[ ${i} -eq ${j} && ${i} -ne 0 ]]; then
			break
		fi

		let n++
	done < "${TEMP_DIR}/source_trim_left.txt"
	if [[ ${i} -ne ${j} ]]; then
		echo "json 获取失败"
		return 1
	fi
	cat "${TEMP_DIR}/source_trim_left.txt" | cut -c -${n}
}

function urldecode() {
    awk -niord '{printf RT?$0chr("0x"substr(RT,2)):$0}' RS=%.. | sed "s/\\\u0026/\&/g"
}

function file_ext_map() {
    local FILE_EXT=$1

cat >${FILE_EXT} <<EOF
audio/mp4   .m4a
audio/webm  .audio.webm
video/mp4   .m4v
video/webm  .video.webm
EOF
}

function file_join_by_col() {
	local FILE_JOIN="${TEMP_DIR}/file_joined.txt"
	local JOIN_FINAL="${TEMP_DIR}/join_final.txt"
	local ARGS=$#
	local i=1

	rm -rf "${FILE_JOIN}"
	rm -rf "${JOIN_FINAL}"


	if [[ ${ARGS} -eq 0 ]]; then exit; fi
	while [[ ${i} -le ${ARGS} ]]
	do
		ARG=$(eval echo '$'"${i}")

		if [[ ! -s "${FILE_JOIN}" || ! -e "${FILE_JOIN}" ]]; then
			cp -f "${ARG}" ${FILE_JOIN}
			let i++
			continue
		fi

		awk 'NR==FNR{a[$1]=$2;next} NR>FNR{if($1 in a)print $0, "\t",a[$1]; else print $0, "\t", "N/A"}' "${ARG}" "${FILE_JOIN}" >"${JOIN_FINAL}"

		cp -f "${JOIN_FINAL}" "${FILE_JOIN}"
		let i++
	done
}

function youtube_header() {
    local HEADER=$1

    cat > ${HEADER} <<EOF
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4596.0 Safari/537.36 Edg/94.0.982.2
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9
Accept-Language: zh-CN,en;q=0.9,zh;q=0.8
Accept-Encoding: identity;q=1, *;q=0
Origin: https://www.youtube.com
Cache-Control: no-cache
Pragma: no-cache
Referer: https://www.youtube.com/
sec-ch-ca: "Chromium";v="94", "Microsoft Edge";v="94", ";Not A Brand";v="99"
sec-ch-ua-arch: "x86"
sec-ch-ua-full-version: "94.0.082.2"
sec-ch-ua-platform: "Linux"
EOF
}

function youtube_parse() {
    local URL_YOUTUBE=$1
    local HEADER=$2
    local YOUTUBE_DL_LIST=$3

    local VIDEO_TITLE
    local START_POSITION
    local VIDEO_DESC

    if [[ "${PROXY_ENABLED}" == "yes" ]]; then
        local PROXY="${PROXY}"
    else
        local PROXY=
    fi

    # 获取Youtube视频播放页面并解析直连地址
    curl --retry 3 --connect-timeout 5 --compressed -L -s -x "${PROXY}" -H @"${HEADER}" "${URL_YOUTUBE}" -o "${RAW_PAGE}"

    if [[ -e "${RAW_PAGE}" ]]; then
        if [[ $(cat "${RAW_PAGE}" | wc -l) -gt 1 ]]; then
            echo -e "页面抓取成功"
        else
            echo "页面抓取失败"
            exit
        fi
    else
        echo "页面抓取失败"
        exit
    fi

    echo -e "开始解析视频信息"
    START_POSITION='var ytInitialPlayerResponse ='    #页面json标志位 
    get_json_from_file "${RAW_PAGE}" "${START_POSITION}" >"${YOUTUBE_JSON}"
    if [[ $? -ne 0 ]]; then exit; fi

    # 获取视频名称和简介
    VIDEO_TITLE=$(json_main -l <"${YOUTUBE_JSON}" | grep \"videoDetails\" \
                | grep \"title\" | awk -F"\t" '{print $(NF)}')
    VIDEO_DESC=$(json_main -l <"${YOUTUBE_JSON}" | grep \"videoDetails\" \
                | grep \"shortDescription\" | awk -F "\t" '{print $(NF)}')

    # 获取URL_LIST
    json_main -l <"${YOUTUBE_JSON}"| grep \"streamingData\" | grep \"adaptiveFormats\" \
        | grep \"url\" | awk -F "\\\[\"streamingData\",\"adaptiveFormats\"," '{print $(NF)}' \
        | sed "s/,\"url\"]//g" | sed "s/\\\\u0026/\&/g" >${TEMP_DIR}/url_list.txt

    # 获取MIME_TYPE
    json_main -l <"${YOUTUBE_JSON}" | grep \"streamingData\" | grep \"adaptiveFormats\" \
        | grep -Ei "(\"video/|\"audio/)" | awk -F "\\\[\"streamingData\",\"adaptiveFormats\"," '{print $(NF)}' \
        | sed "s/,\"mimeType\"\\]\|\"\|\\\//g" | sed "s/;/\\t/g" >${TEMP_DIR}/mime_type.txt

    # 获取QUALITY_LABEL
    json_main -l <"${YOUTUBE_JSON}"| grep \"streamingData\" | grep \"adaptiveFormats\"  \
        | grep -i "\"qualityLabel\"" | awk -F "\\\[\"streamingData\",\"adaptiveFormats\"," '{print $(NF)}'  \
        | sed "s/,\"qualityLabel\"\]\|\"//g" >${TEMP_DIR}/qulit_label.txt

    # 获取码率
    json_main -l <"${YOUTUBE_JSON}"| grep \"streamingData\" | grep \"adaptiveFormats\" \
        | grep -i "\"bitrate\"" | awk -F "\\\[\"streamingData\",\"adaptiveFormats\"," '{print $(NF)}' \
        | sed "s/,\"bitrate\"\]\|\"//g" >${TEMP_DIR}/bitrate.txt

    # 获取文件大小
    json_main -l <"${YOUTUBE_JSON}"| grep \"streamingData\" | grep \"adaptiveFormats\" \
        | grep -i "\"contentLength\""  | awk -F "\\\[\"streamingData\",\"adaptiveFormats\"," '{print $(NF)}' \
        | sed "s/,\"contentLength\"\]\|\"//g" >${TEMP_DIR}/contentLength.txt

    # 合并
    file_join_by_col \
        "${TEMP_DIR}/mime_type.txt" \
        "${TEMP_DIR}/qulit_label.txt" \
        "${TEMP_DIR}/bitrate.txt" \
        "${TEMP_DIR}/contentLength.txt" \
        "${TEMP_DIR}/url_list.txt"


    if [[ -z "$(cat "${TEMP_DIR}/join_final.txt")" ]];then
        echo -e "解析音视频信息失败, 退出！"
        exit
    else
        echo "解析音视频信息成功"
        echo
        echo "=============视频信息==============="
        echo -e "视频名称： ${VIDEO_TITLE}"
        echo -e "视频描述： ${VIDEO_DESC}"
        echo
        echo -e "${VIDEO_TITLE}" | sed "s/^\"//g" | sed "s/\"$//g" \
            | urldecode >${TEMP_DIR}/video_title.txt
    fi

}

function youtube_select_video() {
    local YOUTUBE_DL_LIST=$1
    local SELECTED_URL=$2

    local VIDEO_SELECT
    local SELECTED_RESOLUTION
    local AUDIO_SELECT
    local SELECTED_RATE

    rm -f ${SELECTED_URL}
    # select video
    echo -e "请选择你要下载的视频"
    printf "序号%2s\t文件类型%-12s\t编码方式%-32s\t解析度%-9s\t码率%14s\t文件大小%-10s\n"
    cat "${YOUTUBE_DL_LIST}" \
        | awk -F"\t" '{printf "%6s %-20s %-40s %17s %16.2f kbps %16.2f MB\n",$1,$2,$3,$4,$5/1024,$6/1024/1024}' \
        | awk '{if($2~"video") print $0}'
    read -p  '选择序号: ' VIDEO_SELECT
    if [[ -z ${VIDEO_SELECT} ]]; then
        echo -e "无效的选择"
        exit
    fi
    SELECTED_RESOLUTION=$(cat "${YOUTUBE_DL_LIST}" | awk '{if($2~"video") print $0}' \
        | grep "^${VIDEO_SELECT}[ ]*" | awk '{print $4}')
    if [[ -z ${SELECTED_RESOLUTION} ]]; then
        echo -e "无效的选择"
        exit
    fi
    echo "准备下载分辨率为 ${SELECTED_RESOLUTION} 的视频"

    # get url list
    echo "VIDEO\\t\\c" >>${SELECTED_URL}
    cat "${YOUTUBE_DL_LIST}" | sed -n "${VIDEO_SELECT}p" >>${SELECTED_URL}

    # select audio
    echo -e "请选择你要下载的音频"
    printf "序号%2s\t文件类型%-12s\t编码方式%-32s\t解析度%-9s\t码率%14s\t文件大小%-10s\n"
    cat "${YOUTUBE_DL_LIST}" \
        | awk -F"\t" '{printf "%6s %-20s %-40s %17s %16.2f kbps %16.2f MB\n",$1,$2,$3,$4,$5/1024,$6/1024/1024}' \
        | awk '{if($2~"audio") print $0}'
    read -p  '选择序号: ' AUDIO_SELECT
    if [[ -z "${AUDIO_SELECT}" ]]; then
        echo -e "无效的选择"
        exit
    fi
    SELECTED_RATE=$(cat "${YOUTUBE_DL_LIST}" | awk '{if($2~"audio") print $0}' \
        | grep "^${AUDIO_SELECT}[ ]*"| awk '{print $5}')
    if [[ -z "${SELECTED_RATE}" ]]; then
        echo -e "无效的选择"
        exit
    fi
    echo "准备下载码率为 $(awk 'BEGIN{print "'${SELECTED_RATE}'" / 1024 "kbps"}') 的音频"

    # get url list
    echo "AUDIO\\t\\c" >>${SELECTED_URL}
    cat "${YOUTUBE_DL_LIST}" | sed -n "${AUDIO_SELECT}p" >>${SELECTED_URL}

}


function youtube_multi_thread_download() {
    local REMOTE_FILE=$1
    local HEADER=$2
	local FILE_NAME_RESULT="$3"
	local THREAD_NUMBER=$4
	local TEMP_DIR="/tmp/split_file_$( echo -e "${FILE_NAME_RESULT}" \
        | awk -F '/' '{print $(NF)}' | sed "s/[ ]$//g" | tr ' ' '_')"
    local TOTAL_SIZE=0
    local PID_FOLDER="${TEMP_DIR}/pid"
    local SPLIT_LOG_FOLDER="${TEMP_DIR}/log"

    local RESPONSE_HEADER
    local CONTENT_TYPE
    local TOTAL_SIZE
    local START_TIME
    local BASE_SIZE
    local LAST_SIZE
    local i
    local p
    local MIN_RANGE
    local MAX_RANGE
    local DISIRED_SIZE
    local DL_SIZE
    local END_TIME
    local DURATION
    local SPEED
    local FILE_BYTES

    # enviroment initiation
    rm -rf "${TEMP_DIR}"
    rm -rf "${PID_FOLDER}"
    rm -rf "${SPLIT_LOG_FOLDER}"

    mkdir -p "${TEMP_DIR}"
    mkdir -p "${PID_FOLDER}"
    mkdir -p "${SPLIT_LOG_FOLDER}"

	# get file size_download
    RESPONSE_HEADER=$(curl --retry 5 -L -s -H @"${HEADER}" -X HEAD -I --connect-timeout 10  ${REMOTE_FILE} \
        | tr '\r' '\n' | grep -v "^$" | sed "s/^[ ]//g" | sed "s/[ ]$//g")
    CONTENT_TYPE=$(echo -e "${RESPONSE_HEADER}" | grep -i "^Content-Type" \
        | tail -n 1 | awk '{print $(NF)}' | sed "s/^[ ]//g" | sed "s/[ ]$//g")
    TOTAL_SIZE=$(echo -e "${RESPONSE_HEADER}" | grep -i "^content-length" \
        | tail -n 1 | awk '{print $(NF)}' | sed "s/^[ ]//g" | sed "s/[ ]$//g")
    if [[ ${TOTAL_SIZE} -eq 0 ]]; then
		echo -e "没有从远程获取到文件信息"
		exit 1
	fi
	echo -e "文件大小为: $(awk 'BEGIN{print "'${TOTAL_SIZE}'" / 1024 / 1024}')M"
	echo -e "开始开启 ${THREAD_NUMBER} 个线程进行分块下载..."
    START_TIME=$(date -u +%s)
	# split range base on file bytes
	BASE_SIZE=$((${TOTAL_SIZE} / ${THREAD_NUMBER}))
	LAST_SIZE=$((${TOTAL_SIZE} - ${BASE_SIZE} * $((${THREAD_NUMBER} - 1))))
	i=1
	while [[ ${i} -le ${THREAD_NUMBER} ]]
	do
		{
		MIN_RANGE=$((${i} * ${BASE_SIZE} - ${BASE_SIZE}))
		MAX_RANGE=$((${MIN_RANGE} + ${BASE_SIZE} - 1 ))

		if [[ ${i} -eq ${THREAD_NUMBER} ]]; then
			MAX_RANGE=${TOTAL_SIZE}
		fi

		curl --connect-timeout 60 -L -H  @"${HEADER}" --parallel --parallel-immediate \
            -k -C - -r "${MIN_RANGE}-${MAX_RANGE}" "${REMOTE_FILE}" \
            -o "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 2>"${SPLIT_LOG_FOLDER}/${i}.log"
		}&

        # check whether block create succesfully
        echo "$!" >"${PID_FOLDER}/${i}.pid"
        p=0
        while :
        do
            if [[ ${p} -gt 30 ]]; then
                echo "block[${i}] 创建超时， 退出"
                break
            fi
            kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                sleep 1
                let p++
                continue
            else
                break
            fi
        done

        # check download progress
        {
        b=''
        j=0
        m=0
        n=0
        DL_SPEED=0
        retry=1
        while :
        do
            if [[ ${n} -gt 60 ]]; then
                kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null) 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    # echo -e "block[${i}]超时 ${n} 秒, 继续等待...\r"
                    sleep 1
                    n=0
                    continue
                fi
            fi

            printf "[%s] [%-100s] %d%% %s [%d] \r" "${DL_SPEED}" "${b}" "${j}" " of block" "${i}"
            
            # parse download progress percentage
            j=$(cat "${SPLIT_LOG_FOLDER}/${i}.log" 2>/dev/null \
                | tr '\r' '\n' |  tail -n 1 | sed "s/[ ][ ]*/\t/g" \
                | sed "s/^\t//g" | grep "^[0-9]" | awk '{print $1}')
            if [[ $? -ne 0 ]]; then
                sleep 1
                let n++
                continue
            fi

            DL_SPEED=$(cat "${SPLIT_LOG_FOLDER}/${i}.log" 2>/dev/null \
                | tr '\r' '\n' |  tail -n 1 | sed "s/[ ][ ]*/\t/g" \
                | sed "s/^\t//g" | grep "^[0-9]" | awk '{print $(NF) "/s"}')


            if [[ ${j} -eq ${m} ]]; then
                sleep 1

                let n++
                continue
            fi
            b='#'${b}
            m=${j}
            n=0

            # exit if task completed
            kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null) 2>/dev/null
            if [[ $? -ne 0 ]]; then
                MIN_RANGE=$((${i} * ${BASE_SIZE} - ${BASE_SIZE}))
                MAX_RANGE=$((${MIN_RANGE} + ${BASE_SIZE} - 1 ))
                if [[ ${i} -eq ${THREAD_NUMBER} ]]; then
                    MAX_RANGE=${TOTAL_SIZE}
                    DISIRED_SIZE=$((${TOTAL_SIZE}-${MIN_RANGE}))
                else
                    DISIRED_SIZE=$((${MAX_RANGE}-${MIN_RANGE}+1))
                fi
                b=$(printf %100s | tr ' ' '#')
                DL_SIZE=$(ls "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" -l | awk '{print $5}')

                if [[ ${DL_SIZE} -eq ${DISIRED_SIZE} ]]; then
                    j="$((${DL_SIZE}/${DISIRED_SIZE}*100))"
                    printf "[%s] [%-100s] %d%% %s [%d] \r" "${DL_SPEED}" "${b}" "${j}" " of block" "${i}"
                    break
                else
                    echo "block [${i}] 下载不完全"
                    break
                fi
            fi

        done
        echo
        }&

		let i++
	done
	wait

	# to join all blocks as one file
    if [[ $(ls -p "${TEMP_DIR}" | grep -v "/$" | wc -l) -eq ${THREAD_NUMBER} ]]; then
        END_TIME=$(date -u +%s)
        DURATION=$((${END_TIME} - ${START_TIME}))
        rm -rf ${PID_FOLDER}
        rm -rf ${SPLIT_LOG_FOLDER}

        DL_SIZE=$(du -b -d 1 ${TEMP_DIR} | awk '{print $1}')
        if [[ -z "${DL_SIZE}" ]]; then echo "获取下载文件大小失败"; fi
        SPEED=$((${DL_SIZE} / ${DURATION}))
        SPEED=$(awk 'BEGIN{print "'${SPEED}'" / 1024 / 1024 " MB/s"}')
        echo -e "全部下载完成， 耗时 ${DURATION} 秒, 总平均下载速度 ${SPEED}"
        cat $(ls -p "${TEMP_DIR}/" | grep -v "/$" | sort -n \
            | awk '{print "'${TEMP_DIR}'/" $0}') >"${FILE_NAME_RESULT}"
    else
        echo -e "有部分块下载失败， 请稍后重试"
    fi

	# check file size whether it's matched with content-length
    echo -e "开始合并块文件"
	FILE_BYTES=$(ls -l "${FILE_NAME_RESULT}" |  awk '{print $5}')
	if [[ ${FILE_BYTES} -eq ${TOTAL_SIZE} ]]; then
		echo -e "文件合并成功: ${FILE_NAME_RESULT}"
        # clear all temp files
        rm -rf "${TEMP_DIR}"
        rm -rf "${PID_FOLDER}"
        rm -rf "${SPLIT_LOG_FOLDER}"
	else
		echo -e "文件合并失败"
	fi

	# delete temp file
	# rm -rf "${TEMP_DIR}"
}

function ffmpeg_env() {
    local FFMPEG=$(which ffmpeg 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        which apt-get
        if [[ $? -eq 0 ]]; then
            sudo apt-get install -y ffmpeg
            return 0
        fi
        
        which dnf
        if [[ $? -eq 0 ]]; then
            sudo dnf -y install ffmpeg
            return 0
        fi

        which yum
        if [[ $? -eq 0 ]]; then
            sudo yum -y install ffmpeg
            return 0
        fi
    else
        return 0
    fi
    return 1
}

function youtube_download() {
    local URL_YOUTUBE="$1"
    local DL_FOLDER="$2"
    local DL_URL
    local BITRATES
    local MIME_TYPE
    local FILE_EXT
    local FILE_NAME_VIDEO
    
    # 初始化环境
    rm -rf ${TEMP_DIR}
    mkdir ${TEMP_DIR}

    # 定义 仿冒Youtube http header
    youtube_header "${TEMP_DIR}/header.txt"
    youtube_parse "${URL_YOUTUBE}" "${TEMP_DIR}/header.txt" "${TEMP_DIR}/join_final.txt"
    youtube_select_video "${TEMP_DIR}/join_final.txt" "${TEMP_DIR}/selected_url.txt"

    file_ext_map "${TEMP_DIR}/file_ext_map.txt"

    # 多线程下载
    echo "开始下载视频文件"
    DL_URL=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"video") print $0}' \
        | awk '{print $(NF)}' | sed "s/^\"\|\"$//g" | urldecode)
    BITRATES=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"video") print $0}' | awk '{print $5}')
    MIME_TYPE=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"video") print $0}' | awk '{print $2}')
    FILE_EXT=$(grep "${MIME_TYPE}" "${TEMP_DIR}/file_ext_map.txt" | awk '{print $(NF)}')
    FILE_NAME_VIDEO="${DL_FOLDER}/$(cat "${TEMP_DIR}/video_title.txt")_${BITRATES}${FILE_EXT}"
    youtube_multi_thread_download "${DL_URL}" "${TEMP_DIR}/header.txt" "${FILE_NAME_VIDEO}" 10

    echo "开始下载音频文件"
    DL_URL=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"audio") print $0}' \
        | awk '{print $(NF)}' | sed "s/^\"\|\"$//g" | urldecode)
    BITRATES=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"video") print $0}' | awk '{print $5}')
    MIME_TYPE=$(cat ${TEMP_DIR}/selected_url.txt | awk '{if($2~"audio") print $0}' | awk '{print $2}')
    FILE_EXT=$(grep "${MIME_TYPE}" "${TEMP_DIR}/file_ext_map.txt" | awk '{print $(NF)}')
    FILE_NAME_AUDIO="${DL_FOLDER}/$(cat "${TEMP_DIR}/video_title.txt")_${BITRATES}${FILE_EXT}"
    youtube_multi_thread_download "${DL_URL}" "${TEMP_DIR}/header.txt" "${FILE_NAME_AUDIO}" 10
    # cat info.txt | tr '\r' '\n' | sed "s/[ ][ ]*/\ /g" | grep "k$\|m$\|[0-9]$"

    # 合并转换音视频
    FILE_NAME="${DL_FOLDER}/$(cat "${TEMP_DIR}/video_title.txt")_merged.mp4"
    echo "正在合并音视频>>>> ${FILE_NAME}"
    ffmpeg_env  # 检查ffmpeg是否安装，如没有则自动安装(支持yum/dnf/apt-get包管理)
    if [[ $? -eq 1 ]]; then
        echo "ffmpeg 不存在，跳过音视频合并转换!"
        exit 0
    fi
    ffmpeg -i "${FILE_NAME_VIDEO}" -i "${FILE_NAME_AUDIO}" -c:v copy -c:a aac \
        -strict experimental "${FILE_NAME}" -loglevel error

}

youtube_download "${URL_YOUTUBE}" "${DL_FOLDER}"