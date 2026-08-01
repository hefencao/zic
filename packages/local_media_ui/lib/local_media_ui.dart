library local_media_ui;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bridge/bridge.dart';
import 'package:catalog/catalog.dart';
import 'package:domain/domain.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_media/local_media.dart';
import 'package:media/media.dart'
    show parseWebpPrefixInfo, webpPrefixDeclaresAnimation;
import 'package:pipeline/pipeline.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:reader_runtime/reader_runtime.dart';
import 'package:resource_cache/resource_cache.dart';
import 'package:storage_bridge/storage_bridge.dart';
import 'package:telemetry/telemetry.dart';
import 'package:texture_bridge/texture_bridge.dart';
import 'package:transport/transport.dart';

export 'package:local_media/local_media.dart';
export 'package:reader_runtime/reader_runtime.dart'
    show
        MediaLoadToken,
        PipelineReaderSessionFactory,
        ReaderSessionSettings,
        ReaderSessionSettingsWriter;

part 'src/models_and_preview.dart';
part 'src/catalog_and_codec.dart';
part 'src/local_image_player.dart';
part 'src/local_media_screens.dart';
part 'src/native_webp_player.dart';

const defaultLocalMediaPipelineFactory = PipelineReaderSessionFactory(
  sourceFactory: NativeSourceFactory(),
);