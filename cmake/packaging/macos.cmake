# macOS-specific packaging

if(SUNSHINE_PACKAGE_MACOS)
    # Portable command-line ZIP. Keep executables and their relocated runtime
    # below bin/ without creating a user-facing .app.
    install(TARGETS sunshine
            RUNTIME DESTINATION bin
            COMPONENT Runtime)
    install(TARGETS vd_helper
            RUNTIME DESTINATION bin
            COMPONENT Runtime)
    install(FILES "${PROJECT_SOURCE_DIR}/hid_entitlements.plist"
            DESTINATION .
            COMPONENT Runtime)

    if(SUNSHINE_ENABLE_TRAY)
        # Keep the command-line package relocatable without adopting Sunshine's
        # .app signing flow. The platform plugin is loaded through qt.conf and
        # BundleUtilities places Qt beside bin/ in Frameworks/.
        file(GENERATE
                OUTPUT "${CMAKE_BINARY_DIR}/qt.conf"
                CONTENT "[Paths]\nPlugins = PlugIns\n")
        get_filename_component(LUMINA_QT_PREFIX "${Qt6_DIR}/../../.." ABSOLUTE)
        get_filename_component(LUMINA_QTSVG_PREFIX "${Qt6Svg_DIR}/../../.." ABSOLUTE)
        set(LUMINA_QT_COCOA_PLUGIN
                "${LUMINA_QT_PREFIX}/share/qt/plugins/platforms/libqcocoa.dylib")
        if(NOT EXISTS "${LUMINA_QT_COCOA_PLUGIN}")
            message(FATAL_ERROR "Qt Cocoa platform plugin was not found: ${LUMINA_QT_COCOA_PLUGIN}")
        endif()
        install(FILES "${CMAKE_BINARY_DIR}/qt.conf"
                DESTINATION bin
                COMPONENT Runtime)
        install(FILES "${LUMINA_QT_COCOA_PLUGIN}"
                DESTINATION "bin/PlugIns/platforms"
                COMPONENT Runtime)
        set(LUMINA_RUNTIME_DIRS "${LUMINA_QT_PREFIX}/lib;${LUMINA_QTSVG_PREFIX}/lib")
        # Some Homebrew libraries (e.g. brotli) reference siblings through
        # @rpath, which BundleUtilities only resolves from its search dirs.
        find_program(LUMINA_BREW brew)
        if(LUMINA_BREW)
            execute_process(COMMAND "${LUMINA_BREW}" --prefix
                    OUTPUT_VARIABLE LUMINA_BREW_PREFIX
                    OUTPUT_STRIP_TRAILING_WHITESPACE)
            list(APPEND LUMINA_RUNTIME_DIRS "${LUMINA_BREW_PREFIX}/lib")
        endif()
        install(CODE
                "set(LUMINA_QT_RUNTIME_DIRS \"${LUMINA_RUNTIME_DIRS}\")"
                COMPONENT Runtime)

        install(CODE [[
            set(_package_root "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}")
            set(_lumina "${_package_root}/bin/lumina")
            set(_qt_platform_plugin "${_package_root}/bin/PlugIns/platforms/libqcocoa.dylib")

            include(BundleUtilities)
            set(BU_CHMOD_BUNDLE_ITEMS TRUE)

            # BundleUtilities otherwise places direct-executable dependencies
            # beside bin/, then rejects them as outside the bundle. Keep them
            # under bin/Frameworks so the command-line package remains valid.
            function(gp_item_default_embedded_path_override item path_var)
                if(item MATCHES "[^/]+\\.framework/" OR item MATCHES "\\.dylib$")
                    set(${path_var} "@executable_path/Frameworks" PARENT_SCOPE)
                endif()
            endfunction()

            fixup_bundle("${_lumina}" "${_qt_platform_plugin}" "${LUMINA_QT_RUNTIME_DIRS}")

            # Relocation invalidates upstream signatures. Ad-hoc sign nested
            # libraries first, valid top-level framework bundles next, helper
            # binaries after that, and Lumina itself last. The main executable
            # deliberately receives no restricted HID entitlement here.
            execute_process(COMMAND /usr/bin/xattr -rc "${_package_root}")

            set(_framework_dir "${_package_root}/bin/Frameworks")
            file(GLOB_RECURSE _sign_items
                "${_framework_dir}/*.dylib"
                "${_package_root}/bin/PlugIns/*.dylib"
            )
            if(EXISTS "${_framework_dir}")
                file(GLOB _framework_items
                    LIST_DIRECTORIES true
                    "${_framework_dir}/*.framework"
                )
                list(APPEND _sign_items ${_framework_items})
            endif()

            foreach(_item IN LISTS _sign_items)
                execute_process(
                    COMMAND /usr/bin/codesign --sign - --force "${_item}"
                    RESULT_VARIABLE _sign_result
                )
                if(NOT _sign_result EQUAL 0)
                    message(FATAL_ERROR "Failed to ad-hoc sign packaged runtime: ${_item}")
                endif()
            endforeach()

            foreach(_executable IN ITEMS "${_package_root}/bin/vd_helper" "${_lumina}")
                execute_process(
                    COMMAND /usr/bin/codesign --sign - --force "${_executable}"
                    RESULT_VARIABLE _sign_result
                )
                if(NOT _sign_result EQUAL 0)
                    message(FATAL_ERROR "Failed to ad-hoc sign packaged executable: ${_executable}")
                endif()
            endforeach()
        ]] COMPONENT Runtime)
    endif()

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
