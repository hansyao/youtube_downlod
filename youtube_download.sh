#!/bin/sh

# 初始化全局变量
URL_YOUTUBE=$(echo -e "$1")
if [[ -z $2 ]]; then DL_FOLDER=`pwd`; else DL_FOLDER="$2"; fi
if [[ -z $3 ]]; then THREAD_NUMBER=10; else THREAD_NUMBER=$3; fi
PROXY_ENABLED=yes
PROXY='socks5h://192.168.50.1:23456'

TEMP_DIR='/tmp/tmp_youtube'
RAW_PAGE="${TEMP_DIR}/youtube_raw_page.html"
YOUTUBE_JSON="${TEMP_DIR}/youtube.json"

function get_json_from_file() {
	local SOURCE_FILE_NAME=$1
	local START_POSITION=$2
    local YOUTUBE_JSON=$3
	local TEMP_DIR=${TEMP_DIR}

	# trim left from START_POSITION
	cat "${SOURCE_FILE_NAME}" | tr '\n|\r' ' ' | awk -F "${START_POSITION}" '{print $(NF)}' \
		| sed "s/^[ ][ ]*\|^[\t][\t]*//g" >"${TEMP_DIR}/source_trim_left.txt"

	# get END_POSITION
    cat "${TEMP_DIR}/source_trim_left.txt" | jq -r '.' 2>/dev/null >"${YOUTUBE_JSON}"

    if [[ $(cat "${YOUTUBE_JSON}" | wc -l) -gt 0 ]]; then return 0; else return 1; fi
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
    if [[ "${PROXY_ENABLED}" == 'yes' ]]; then
        curl --retry 3 --connect-timeout 5 -L -s -x "${PROXY}" -H @"${HEADER}" "${URL_YOUTUBE}" -o "${RAW_PAGE}"
    else
        curl --retry 3 --connect-timeout 5 -L -s -H @"${HEADER}" "${URL_YOUTUBE}" -o "${RAW_PAGE}"
    fi

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
    get_json_from_file "${RAW_PAGE}" "${START_POSITION}" "${YOUTUBE_JSON}"
    if [[ $? -ne 0 ]]; then exit; fi

    # 获取视频名称和简介
    VIDEO_TITLE=$(jq -r '.videoDetails.title' <"${YOUTUBE_JSON}")
    VIDEO_DESC=$(jq -r '.videoDetails.shortDescription' <"${YOUTUBE_JSON}")

    jq -rn '["itag", "mimeType","qualityLabel","bitrate","contentLength", "url"] as $fields
        | (
            $fields,
            ($fields | map(length*"-")),
            (inputs | .streamingData.adaptiveFormats[] | [.itag, .mimeType, .qualityLabel, .bitrate, .contentLength, .url])
        ) | @tsv' <${YOUTUBE_JSON} \
        >"${TEMP_DIR}/join_final.txt"

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
            >${TEMP_DIR}/video_title.txt
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
    printf "标识%2s\t文件类型 & 编码方式%-50s\t解析度%9s\t码率%14s\t文件大小%10s\n"
    cat "${YOUTUBE_DL_LIST}" \
        | awk -F"\t" '{printf "%-6s %-60s %17s %16.2f kbps %16.2f MB\n",$1,$2,$3,$4/1024,$5/1024/1024}' \
        | awk '{if($2~"video") print $0}'
    read -p  '选择标识号: ' VIDEO_SELECT
    if [[ -z ${VIDEO_SELECT} ]]; then
        echo -e "无效的选择"
        exit
    fi
    SELECTED_RESOLUTION=$(cat "${YOUTUBE_DL_LIST}" | awk '{if($2~"video") print $0}' \
        | grep "^${VIDEO_SELECT}[ ]*" | awk -F "\t" '{print $3}')
    if [[ -z ${SELECTED_RESOLUTION} ]]; then
        echo -e "无效的选择"
        exit
    fi
    echo "准备下载分辨率为 ${SELECTED_RESOLUTION} 的视频"

    # get url list
    echo "VIDEO\\t\\c" >>${SELECTED_URL}
    cat "${YOUTUBE_DL_LIST}" | grep "^${VIDEO_SELECT}[ ]*" >>${SELECTED_URL}

    # select audio
    echo -e "请选择你要下载的音频"
    printf "标识%2s\t文件类型 & 编码方式%-50s\t解析度%9s\t码率%14s\t文件大小%10s\n"
    cat "${YOUTUBE_DL_LIST}" \
        | awk -F"\t" '{printf "%-6s %-60s %17s %16.2f kbps %16.2f MB\n",$1,$2,$3,$4/1024,$5/1024/1024}' \
        | awk '{if($2~"audio") print $0}'
    read -p  '选择标识号: ' AUDIO_SELECT
    if [[ -z "${AUDIO_SELECT}" ]]; then
        echo -e "无效的选择"
        exit
    fi
    SELECTED_RATE=$(cat "${YOUTUBE_DL_LIST}" | awk '{if($2~"audio") print $0}' \
        | grep "^${AUDIO_SELECT}[ ]*" | awk -F "\t" '{print $4}')
    if [[ -z "${SELECTED_RATE}" ]]; then
        echo -e "无效的选择"
        exit
    fi
    echo "准备下载码率为 $(awk 'BEGIN{print "'${SELECTED_RATE}'" / 1024 "kbps"}') 的音频"

    # get url list
    echo "AUDIO\\t\\c" >>${SELECTED_URL}
    cat "${YOUTUBE_DL_LIST}" | grep "^${AUDIO_SELECT}[ ]*"  >>${SELECTED_URL}

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
    local DL_SIZE=0
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
    if [[ "${PROXY_ENABLED}" == 'yes' ]]; then
        RESPONSE_HEADER=$(curl -x "${PROXY}" --retry 5 -L -s -H @"${HEADER}" -X HEAD -I --connect-timeout 10  ${REMOTE_FILE} \
            | tr '\r' '\n' | grep -v "^$" | sed "s/^[ ]//g" | sed "s/[ ]$//g")
    else
        RESPONSE_HEADER=$(curl --retry 5 -L -s -H @"${HEADER}" -X HEAD -I --connect-timeout 10  ${REMOTE_FILE} \
            | tr '\r' '\n' | grep -v "^$" | sed "s/^[ ]//g" | sed "s/[ ]$//g")
    fi
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
        MIN_RANGE=$((${i} * ${BASE_SIZE} - ${BASE_SIZE}))
        MAX_RANGE=$((${MIN_RANGE} + ${BASE_SIZE} - 1 ))
        if [[ ${i} -eq ${THREAD_NUMBER} ]]; then
            MAX_RANGE=${TOTAL_SIZE}
            DISIRED_SIZE=$((${TOTAL_SIZE}-${MIN_RANGE}))
        else
            DISIRED_SIZE=$((${MAX_RANGE}-${MIN_RANGE}+1))
        fi

		{
        if [[ "${PROXY_ENABLED}" == 'yes' ]]; then
		    curl -x "${PROXY}" --connect-timeout 60 -L -H  @"${HEADER}" --parallel --parallel-immediate \
                -k -C - -r "${MIN_RANGE}-${MAX_RANGE}" "${REMOTE_FILE}" \
                -o "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 2>"${SPLIT_LOG_FOLDER}/${i}.log"
        else
		    curl --connect-timeout 60 -L -H  @"${HEADER}" --parallel --parallel-immediate \
                -k -C - -r "${MIN_RANGE}-${MAX_RANGE}" "${REMOTE_FILE}" \
                -o "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 2>"${SPLIT_LOG_FOLDER}/${i}.log"
        fi

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
        j=0     # download percentage
        m=0     # download percentage (previously)
        n=0     # waiting seconds
        retry=1 # 重试
        DL_SPEED=0  # download speed
        while :
        do
            if [[ ${n} -gt 60 ]]; then
                kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null) 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    # 只要 curl 进程未退出则轮询等待"
                    sleep 1
                    n=0
                    continue
                fi
            fi

            printf "[%s] [%-100s] %d%% %s [%d] \r" "${DL_SPEED}" "${b}" "${j}" " of block" "${i}"
            
            # parse download progress percentage
            # j=$(cat "${SPLIT_LOG_FOLDER}/${i}.log" 2>/dev/null \
            #     | tr '\r' '\n' |  tail -n 1 | sed "s/[ ][ ]*/\t/g" \
            #     | sed "s/^\t//g" | grep "^[0-9]" | awk '{print $1}')
            
            if [[ -s "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" ]]; then
                # echo "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 
                DL_SIZE=$(du -b -d 1 "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" | awk '{print $1}')
                j=$(( 100 * ${DL_SIZE} / ${DISIRED_SIZE} ))
            else
                j=0
                let n++
                sleep 1
            fi

            DL_SPEED=$(cat "${SPLIT_LOG_FOLDER}/${i}.log" 2>/dev/null \
                | tr '\r' '\n' |  tail -n 1 | sed "s/[ ][ ]*/\t/g" \
                | sed "s/^\t//g" | grep "^[0-9]" | awk '{print $(NF) "/s"}')
            # echo DL_SPEED:$DL_SPEED DL_SIZE:$DL_SIZE TOTAL_SIZE:$TOTAL_SIZE j:${j}
            if [[ ${j} -eq ${m} ]]; then
                # 如下载进度没有变化，则轮询等待
                kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null) 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    # 只要 curl 进程未退出则轮询等待"
                    sleep 1
                    n=0
                    continue
                fi
            fi
            b='#'${b}
            m=${j}
            n=0

            # exit if task completed
            kill -0 $(cat "${PID_FOLDER}/${i}.pid" 2>/dev/null) 2>/dev/null
            if [[ $? -ne 0 ]]; then
                sleep 1
                DL_SIZE=$(du -b -d 1 "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" | awk '{print $1}')
                if [[ ${DL_SIZE} -ge ${DISIRED_SIZE} ]]; then
                    j=$((100 * ${DL_SIZE} / ${DISIRED_SIZE}))
                    b=$(printf %100s | tr ' ' '#')
                    printf "[%s] [%-100s] %d%% %s [%d] \r" "${DL_SPEED}" "${b}" "${j}" " of block" "${i}"
                    break
                else
                    echo "block [${i}] 超时退出未完成，重试【${retry}】..."
                    rm -f "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}"
                    {
                    if [[ "${PROXY_ENABLED}" == 'yes' ]]; then
                        curl -x "${PROXY}" --connect-timeout 60 -L -H  @"${HEADER}" --parallel --parallel-immediate \
                            -k -C - -r "${MIN_RANGE}-${MAX_RANGE}" "${REMOTE_FILE}" \
                            -o "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 2>"${SPLIT_LOG_FOLDER}/${i}.log"
                    else
                        curl --connect-timeout 60 -L -H  @"${HEADER}" --parallel --parallel-immediate \
                            -k -C - -r "${MIN_RANGE}-${MAX_RANGE}" "${REMOTE_FILE}" \
                            -o "${TEMP_DIR}/${MIN_RANGE}-${MAX_RANGE}" 2>"${SPLIT_LOG_FOLDER}/${i}.log"
                    fi
                    }&
                    echo "$!" >"${PID_FOLDER}/${i}.pid"
                    n=0
                    let retry++
                    echo
                fi
            fi
            sleep 1
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
    local THREAD_NUMBER=$3
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
    DL_URL=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"video") print $(NF)}' | sed "s/^\"\|\"$//g" )
    BITRATES=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"video") print $4}')
    MIME_TYPE=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"video") print $2}' | awk -F ";" '{print $1}')
    FILE_EXT=$(grep "${MIME_TYPE}" "${TEMP_DIR}/file_ext_map.txt" | awk '{print $(NF)}')
    FILE_NAME_VIDEO="${DL_FOLDER}/$(cat "${TEMP_DIR}/video_title.txt")_${BITRATES}${FILE_EXT}"
    youtube_multi_thread_download "${DL_URL}" "${TEMP_DIR}/header.txt" "${FILE_NAME_VIDEO}" "${THREAD_NUMBER}"

    echo "开始下载音频文件"
    DL_URL=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"audio") print $(NF)}' | sed "s/^\"\|\"$//g" )
    BITRATES=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"audio") print $4}')
    MIME_TYPE=$(cat "${TEMP_DIR}/selected_url.txt" | awk -F "\t" '{if($2~"audio") print $2}' | awk -F ";" '{print $1}')
    FILE_EXT=$(grep "${MIME_TYPE}" "${TEMP_DIR}/file_ext_map.txt" | awk '{print $(NF)}')
    FILE_NAME_AUDIO="${DL_FOLDER}/$(cat "${TEMP_DIR}/video_title.txt")_${BITRATES}${FILE_EXT}"
    youtube_multi_thread_download "${DL_URL}" "${TEMP_DIR}/header.txt" "${FILE_NAME_AUDIO}" "${THREAD_NUMBER}"
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

youtube_download "${URL_YOUTUBE}" "${DL_FOLDER}" "${THREAD_NUMBER}"