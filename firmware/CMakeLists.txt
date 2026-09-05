cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# CI checks out without tags, so git describe cannot name the release.
if(DEFINED ENV{PROJECT_VER})
    set(PROJECT_VER "$ENV{PROJECT_VER}")
endif()
project(esp-hci-bridge)
