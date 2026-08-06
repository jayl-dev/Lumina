# macOS-specific packaging

if(SUNSHINE_PACKAGE_MACOS)
    # Portable command-line ZIP. Keep executables in bin/ and dependencies in
    # a sibling Frameworks directory, matching BundleUtilities' relocatable
    # layout without creating a user-facing .app.
    install(TARGETS sunshine
            RUNTIME DESTINATION bin
            COMPONENT Runtime)
    install(TARGETS vd_helper
            RUNTIME DESTINATION bin
            COMPONENT Runtime)
    install(FILES "${PROJECT_SOURCE_DIR}/hid_entitlements.plist"
            DESTINATION .
            COMPONENT Runtime)

    set(CPACK_PACKAGE_FILE_NAME "${CMAKE_PROJECT_NAME}")
else()
    install(FILES "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/misc/uninstall_pkg.sh"
            DESTINATION "${SUNSHINE_ASSETS_DIR}")
endif()

install(DIRECTORY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
        DESTINATION "${SUNSHINE_ASSETS_DIR}")
# copy assets to build directory, for running without install
file(COPY "${SUNSHINE_SOURCE_ASSETS_DIR}/macos/assets/"
        DESTINATION "${CMAKE_BINARY_DIR}/assets")
