// Copyright (c) $today.year, Jiakuo Liu. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';

import 'package:flutter/widgets.dart';

import 'leak_detector_task.dart';
import 'leak_data.dart';
import 'leak_record_handler.dart';
import 'vm_service_utils.dart';

typedef LeakEventListener = void Function(DetectorEvent event);

///泄漏检测主要工具类
class LeakDetector {
  static LeakDetector _instance;
  static int maxRetainingPath;
  Map<String, Expando> _watchGroup = {};
  Queue<DetectorTask> _checkTaskQueue = Queue();
  StreamController<LeakedInfo> _onLeakedStreamController = StreamController.broadcast();
  StreamController<DetectorEvent> _onEventStreamController = StreamController.broadcast();

  DetectorTask _currentTask;

  Stream<LeakedInfo> get onLeakedStream => _onLeakedStreamController.stream;

  Stream<DetectorEvent> get onEventStream => _onEventStreamController.stream;

  factory LeakDetector() {
    _instance ??= LeakDetector._();
    return _instance;
  }

  void init({int maxRetainingPath = 300}) {
    LeakDetector.maxRetainingPath = maxRetainingPath;
  }

  LeakDetector._() {
    assert(() {
      VmServerUtils().getVmService();
      onLeakedStream.listen(saveLeakedRecord);
      return true;
    }());
  }

  ensureReleaseAsync(String group, {int delay = 0}) async {
    Expando expando = _watchGroup[group];
    _watchGroup.remove(group);
    group = null;
    if (expando != null) {
      //延时检测，有些state会在页面退出之后延迟释放，这并不表示就一定是内存泄漏。
      //比如runZone就会延时释放
      Timer(Duration(milliseconds: delay), () async {
        // add a check task
        _checkTaskQueue.add(
          DetectorTask(
            expando,
            sink: _onEventStreamController.sink,
            onStart: () => _onEventStreamController.add(DetectorEvent(DetectorEventType.check, data: group)),
            onResult: (LeakedInfo leakInfo) {
              _currentTask = null;
              _checkStartTask();
              //notify listeners
              if(leakInfo != null && leakInfo.isNotEmpty) {
                _onLeakedStreamController.add(leakInfo);
              }
            },
          ),
        );
        expando = null;
        _checkStartTask();
      });
    }
  }

  ///start check task if not empty
  void _checkStartTask() {
    if (_checkTaskQueue.isNotEmpty && _currentTask == null) {
      _currentTask = _checkTaskQueue.removeFirst();
      _currentTask.start();
    }
  }

  ///[group] 认为可以在一块释放的对象组，一般在一个[State]中想监听的对象
  addWatchObject(Object obj, [String group]) {
    if (LeakDetector.maxRetainingPath == null) return;

    _onEventStreamController.add(DetectorEvent(DetectorEventType.addObject, data: group));

    _checkType(obj);
    Object key = obj;
    if (group != null) {
      key = group;
    }
    Expando expando = _watchGroup[key];
    expando ??= Expando('LeakChecker$key');
    expando[obj] = true;
    _watchGroup[key] = expando;
  }

  static _checkType(object) {
    if ((object == null) ||
        (object is bool) ||
        (object is num) ||
        (object is String) ||
        (object is Pointer) ||
        (object is Struct)) {
      throw new ArgumentError.value(
          object, "Expandos are not allowed on strings, numbers, booleans, null, Pointers, Structs or Unions.");
    }
  }
}

class DetectorEvent {
  final DetectorEventType type;
  final dynamic data;

  @override
  String toString() {
    return '$type, $data';
  }

  DetectorEvent(this.type, {this.data});
}

enum DetectorEventType {
  addObject,
  check,
  startGC,
  endGc,
  startAnalyze,
  endAnalyze,
}
