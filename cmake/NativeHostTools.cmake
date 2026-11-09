# Build lemon, re2c, and zipdir with the host compiler and import the native
# binaries into an Emscripten (or other cross) build. Build rules keep using
# the lemon, re2c, and zipdir target names; those names resolve to host paths.

function(_uzdoom_first_existing out_var)
	foreach(candidate IN LISTS ARGN)
		if(EXISTS "${candidate}" AND NOT IS_DIRECTORY "${candidate}")
			set(${out_var} "${candidate}" PARENT_SCOPE)
			return()
		endif()
	endforeach()
	set(${out_var} "" PARENT_SCOPE)
endfunction()

function(_uzdoom_reject_emscripten_compiler compiler language)
	get_filename_component(compiler_real "${compiler}" REALPATH)
	if(compiler_real MATCHES "emsdk|emscripten" OR compiler MATCHES "emcc|em\\+\\+")
		message(FATAL_ERROR
			"Refusing to build host tools with the Emscripten ${language} compiler:\n"
			"  ${compiler}\n"
			"Set HOST_${language}_COMPILER to the native compiler.")
	endif()
endfunction()

function(_uzdoom_detect_host_compilers out_c out_cxx)
	set(host_c "${HOST_C_COMPILER}")
	set(host_cxx "${HOST_CXX_COMPILER}")

	if(NOT host_c OR NOT host_cxx)
		set(detected_c "")
		set(detected_cxx "")
		if(CMAKE_HOST_APPLE)
			execute_process(COMMAND xcrun --find clang
				OUTPUT_VARIABLE detected_c
				OUTPUT_STRIP_TRAILING_WHITESPACE
				RESULT_VARIABLE xcrun_c_result)
			execute_process(COMMAND xcrun --find clang++
				OUTPUT_VARIABLE detected_cxx
				OUTPUT_STRIP_TRAILING_WHITESPACE
				RESULT_VARIABLE xcrun_cxx_result)
			if(NOT xcrun_c_result EQUAL 0)
				set(detected_c "")
			endif()
			if(NOT xcrun_cxx_result EQUAL 0)
				set(detected_cxx "")
			endif()
		endif()
		if(NOT detected_c)
			_uzdoom_first_existing(detected_c
				/usr/bin/gcc /usr/local/bin/gcc /opt/homebrew/bin/gcc
				/usr/bin/cc /usr/local/bin/cc
				/usr/bin/clang /usr/local/bin/clang /opt/homebrew/bin/clang)
		endif()
		if(NOT detected_cxx)
			_uzdoom_first_existing(detected_cxx
				/usr/bin/g++ /usr/local/bin/g++ /opt/homebrew/bin/g++
				/usr/bin/c++ /usr/local/bin/c++
				/usr/bin/clang++ /usr/local/bin/clang++ /opt/homebrew/bin/clang++)
		endif()
		if(NOT host_c)
			set(host_c "${detected_c}")
		endif()
		if(NOT host_cxx)
			set(host_cxx "${detected_cxx}")
		endif()
	endif()

	if(NOT host_c OR NOT host_cxx)
		message(FATAL_ERROR
			"Could not find a native compiler for lemon, re2c, and zipdir.\n"
			"Set HOST_C_COMPILER and HOST_CXX_COMPILER to the host gcc/clang.")
	endif()
	_uzdoom_reject_emscripten_compiler("${host_c}" "C")
	_uzdoom_reject_emscripten_compiler("${host_cxx}" "CXX")
	set(${out_c} "${host_c}" PARENT_SCOPE)
	set(${out_cxx} "${host_cxx}" PARENT_SCOPE)
endfunction()

# Configure and build the host tools. Sets <out_import> to ImportExecutables.cmake
# in the parent scope. The caller includes that file.
function(uzdoom_build_native_host_tools out_import)
	_uzdoom_detect_host_compilers(host_c host_cxx)
	message(STATUS "Native host C compiler: ${host_c}")
	message(STATUS "Native host C++ compiler: ${host_cxx}")

	find_program(UZDOOM_HOST_NINJA NAMES ninja)
	if(UZDOOM_HOST_NINJA AND NOT UZDOOM_HOST_NINJA MATCHES "emsdk|emscripten")
		set(host_generator Ninja)
		set(host_make_program "${UZDOOM_HOST_NINJA}")
	else()
		set(host_generator "Unix Makefiles")
		set(host_make_program "")
	endif()

	set(host_tools_dir "${CMAKE_BINARY_DIR}/host-tools")
	set(host_import "${host_tools_dir}/ImportExecutables.cmake")
	message(STATUS "Building native lemon, re2c, and zipdir in ${host_tools_dir}")

	set(configure_command
		${CMAKE_COMMAND} -E env
			--unset=CC
			--unset=CXX
			--unset=AR
			--unset=RANLIB
			--unset=NM
			--unset=STRIP
			--unset=CFLAGS
			--unset=CXXFLAGS
			--unset=LDFLAGS
			--unset=CMAKE_TOOLCHAIN_FILE
			--unset=CMAKE_C_COMPILER
			--unset=CMAKE_CXX_COMPILER
			--unset=CMAKE_C_FLAGS
			--unset=CMAKE_CXX_FLAGS
			--unset=CMAKE_EXE_LINKER_FLAGS
		${CMAKE_COMMAND}
			-S "${CMAKE_SOURCE_DIR}"
			-B "${host_tools_dir}"
			-G "${host_generator}"
			-DCMAKE_BUILD_TYPE=Release
			-DCMAKE_C_COMPILER=${host_c}
			-DCMAKE_CXX_COMPILER=${host_cxx}
			-DBUILD_HOST_TOOLS_ONLY=ON
			-DBUILD_SHARED_LIBS=OFF
	)
	if(host_make_program)
		list(APPEND configure_command -DCMAKE_MAKE_PROGRAM=${host_make_program})
	endif()

	execute_process(
		COMMAND ${configure_command}
		RESULT_VARIABLE configure_result
	)
	if(NOT configure_result EQUAL 0)
		message(FATAL_ERROR
			"Failed to configure native host tools (exit ${configure_result}).\n"
			"Compiler: ${host_c}\n"
			"If this directory is stale, delete ${host_tools_dir} and configure again.")
	endif()

	execute_process(
		COMMAND ${CMAKE_COMMAND} --build "${host_tools_dir}" --target lemon re2c zipdir --parallel
		RESULT_VARIABLE build_result
	)
	if(NOT build_result EQUAL 0)
		message(FATAL_ERROR
			"Failed to build native lemon, re2c, and zipdir (exit ${build_result}).")
	endif()
	if(NOT EXISTS "${host_import}")
		message(FATAL_ERROR "Native host tools did not write ${host_import}")
	endif()
	set(${out_import} "${host_import}" PARENT_SCOPE)
endfunction()

function(_uzdoom_reject_wasm_binary path tool)
	if(NOT EXISTS "${path}")
		message(FATAL_ERROR "Native ${tool} was not produced at:\n  ${path}")
	endif()
	file(READ "${path}" magic LIMIT 4 HEX)
	if(magic STREQUAL "0061736d")
		message(FATAL_ERROR
			"${tool} is a WebAssembly binary:\n  ${path}\n"
			"Set HOST_C_COMPILER and HOST_CXX_COMPILER to native compilers.")
	endif()
endfunction()

# Point every consumer configuration at the native binary that was exported,
# and make sure node is not used to launch it.
function(uzdoom_map_host_tool_configs)
	foreach(tool lemon re2c zipdir)
		if(NOT TARGET ${tool})
			message(FATAL_ERROR "ImportExecutables.cmake did not provide '${tool}'")
		endif()
		set(found_cfg "")
		set(found_path "")
		foreach(cfg RELEASE RELWITHDEBINFO MINSIZEREL DEBUG)
			get_target_property(loc ${tool} IMPORTED_LOCATION_${cfg})
			if(loc AND NOT loc MATCHES "NOTFOUND$")
				set(found_cfg "${cfg}")
				set(found_path "${loc}")
				break()
			endif()
		endforeach()
		if(NOT found_path)
			get_target_property(found_path ${tool} IMPORTED_LOCATION)
			if(found_path MATCHES "NOTFOUND$")
				set(found_path "")
			endif()
		endif()
		if(NOT found_path)
			message(FATAL_ERROR "Imported ${tool} has no native binary path")
		endif()
		_uzdoom_reject_wasm_binary("${found_path}" "${tool}")
		if(found_cfg)
			foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
				set_target_properties(${tool} PROPERTIES MAP_IMPORTED_CONFIG_${cfg} "${found_cfg}")
			endforeach()
		endif()
		set_target_properties(${tool} PROPERTIES CROSSCOMPILING_EMULATOR "")
		message(STATUS "Native ${tool}: ${found_path}")
	endforeach()
endfunction()
