idf_component_register(
    SRCS "glue.c" "ota.c"
    INCLUDE_DIRS "."
    REQUIRES bt esp_eth esp_netif esp_event nvs_flash lwip esp_timer esp_http_server app_update esp_app_format
)

# The bridge logic is a Zig object built by the repo root build.zig.
# ZIG must point at a Zig with Xtensa support (Espressif fork).
set(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")
if(DEFINED ENV{ZIG})
    set(ZIG "$ENV{ZIG}")
else()
    set(ZIG "zig")
endif()
set(ZIG_PREFIX "${CMAKE_BINARY_DIR}/zig")
set(ZIG_OBJ "${ZIG_PREFIX}/obj/bridge.o")
file(GLOB_RECURSE ZIG_SOURCES
    "${REPO_ROOT}/common/*.zig"
    "${REPO_ROOT}/firmware/main/*.zig"
    "${REPO_ROOT}/build.zig"
)
add_custom_command(
    OUTPUT "${ZIG_OBJ}"
    COMMAND "${ZIG}" build firmware -Dfirmware=true -Doptimize=ReleaseSafe
            --prefix "${ZIG_PREFIX}" --cache-dir "${CMAKE_BINARY_DIR}/zig-cache"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS ${ZIG_SOURCES}
    COMMENT "Compiling Zig bridge object"
    VERBATIM
)
add_custom_target(bridge_zig DEPENDS "${ZIG_OBJ}")
add_dependencies(${COMPONENT_LIB} bridge_zig)
target_link_libraries(${COMPONENT_LIB} PUBLIC "${ZIG_OBJ}")
