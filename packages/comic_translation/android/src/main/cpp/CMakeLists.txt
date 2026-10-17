cmake_minimum_required(VERSION 3.22.1)
project(zic_comic_translation LANGUAGES C CXX)

add_library(zic_translation_cpu SHARED comic_translation_cpu.cpp)
target_compile_features(zic_translation_cpu PRIVATE cxx_std_17)

# arm64 builds require the pinned on-device runtime. Other ABIs retain OCR/API
# support. Model files remain user-installed data rather than APK assets.
set(_require_local OFF)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(_require_local ON)
endif()
option(ZIC_REQUIRE_LOCAL_TRANSLATION
    "Fail configuration when the local translation runtime is unavailable" ${_require_local})
set(ZIC_TRANSLATION_RUNTIME_REVISION "" CACHE STRING
    "Runtime package revision used to invalidate Android CMake configuration")
set(CTRANSLATE2_ROOT "$ENV{CTRANSLATE2_ROOT}" CACHE PATH "CTranslate2 Android package")
set(SENTENCEPIECE_ROOT "$ENV{SENTENCEPIECE_ROOT}" CACHE PATH "SentencePiece Android package")
if(NOT CTRANSLATE2_ROOT)
    set(CTRANSLATE2_ROOT
        "${ZIC_TRANSLATION_RUNTIME}/ctranslate2")
endif()
if(NOT SENTENCEPIECE_ROOT)
    set(SENTENCEPIECE_ROOT
        "${ZIC_TRANSLATION_RUNTIME}/sentencepiece")
endif()
set(_ctranslate2_lib "${CTRANSLATE2_ROOT}/lib/${ANDROID_ABI}/libctranslate2.so")
set(_sentencepiece_lib "${SENTENCEPIECE_ROOT}/lib/${ANDROID_ABI}/libsentencepiece.so")
if(EXISTS "${CTRANSLATE2_ROOT}/include/ctranslate2/translator.h" AND
   EXISTS "${SENTENCEPIECE_ROOT}/include/sentencepiece_processor.h" AND
   EXISTS "${_ctranslate2_lib}" AND EXISTS "${_sentencepiece_lib}")
    add_library(ctranslate2 SHARED IMPORTED)
    set_target_properties(ctranslate2 PROPERTIES IMPORTED_LOCATION "${_ctranslate2_lib}")
    add_library(sentencepiece SHARED IMPORTED)
    set_target_properties(sentencepiece PROPERTIES IMPORTED_LOCATION "${_sentencepiece_lib}")
    add_library(zic_translation SHARED comic_translation.cpp)
    target_compile_features(zic_translation PRIVATE cxx_std_17)
    target_include_directories(zic_translation PRIVATE
        "${CTRANSLATE2_ROOT}/include"
        "${SENTENCEPIECE_ROOT}/include"
    )
    target_link_libraries(zic_translation ctranslate2 sentencepiece log)
    set_target_properties(zic_translation PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
else()
    if(ZIC_REQUIRE_LOCAL_TRANSLATION)
        message(FATAL_ERROR
            "CTranslate2/SentencePiece Android runtime is missing for ${ANDROID_ABI}. "
            "Run tool/comic_translation/build_android_runtime.sh first.")
    endif()
    message(STATUS
        "CTranslate2/SentencePiece Android packages not set; local translation disabled")
endif()

# Hy-MT1.5 2-bit uses the Q2_0c GGUF kernel from a pinned llama.cpp runtime.
set(LLAMA_ROOT "$ENV{LLAMA_ROOT}" CACHE PATH "llama.cpp Android package")
if(NOT LLAMA_ROOT)
    set(LLAMA_ROOT
        "${ZIC_TRANSLATION_RUNTIME}/llama")
endif()
set(_llama_lib "${LLAMA_ROOT}/lib/${ANDROID_ABI}/libllama.so")
set(_ggml_lib "${LLAMA_ROOT}/lib/${ANDROID_ABI}/libggml.so")
set(_ggml_base_lib "${LLAMA_ROOT}/lib/${ANDROID_ABI}/libggml-base.so")
set(_ggml_cpu_lib "${LLAMA_ROOT}/lib/${ANDROID_ABI}/libggml-cpu.so")
if(EXISTS "${LLAMA_ROOT}/include/llama.h" AND
   EXISTS "${LLAMA_ROOT}/include/ggml-backend.h" AND
   EXISTS "${_llama_lib}" AND EXISTS "${_ggml_lib}" AND
   EXISTS "${_ggml_base_lib}" AND EXISTS "${_ggml_cpu_lib}")
    foreach(_library llama ggml ggml-base ggml-cpu)
        string(REPLACE "-" "_" _target "${_library}")
        add_library(${_target} SHARED IMPORTED)
        set_target_properties(${_target} PROPERTIES IMPORTED_LOCATION
            "${LLAMA_ROOT}/lib/${ANDROID_ABI}/lib${_library}.so")
    endforeach()
    add_library(zic_hymt SHARED comic_translation_hymt.cpp)
    target_compile_features(zic_hymt PRIVATE cxx_std_17)
    target_include_directories(zic_hymt PRIVATE "${LLAMA_ROOT}/include")
    target_link_libraries(zic_hymt llama ggml ggml_base ggml_cpu log android)
    set_target_properties(zic_hymt PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}"
    )
else()
    if(ZIC_REQUIRE_LOCAL_TRANSLATION)
        message(FATAL_ERROR
            "llama.cpp Android runtime is missing for ${ANDROID_ABI}. "
            "Run tool/comic_translation/build_android_runtime.sh first.")
    endif()
    message(STATUS "llama.cpp Android package not set; Hy-MT translation disabled")
endif()
