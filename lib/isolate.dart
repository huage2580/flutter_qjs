/*
 * @Description: 
 * @Author: ekibun
 * @Date: 2020-10-02 13:49:03
 * @LastEditors: ekibun
 * @LastEditTime: 2020-10-03 22:21:31
 */
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_qjs/wrapper.dart';

class IsolateJSFunction {
  int val;
  int ctx;
  SendPort port;
  IsolateJSFunction(this.ctx, this.val, this.port);

  Future<dynamic> invoke(List<dynamic> arguments) async {
    if (0 == val ?? 0) return;
    var evaluatePort = ReceivePort();
    port.send({
      'type': 'call',
      'ctx': ctx,
      'val': val,
      'args': _encodeData(arguments),
      'port': evaluatePort.sendPort,
    });
    var result = await evaluatePort.first;
    if (result['data'] != null)
      return _decodeData(result['data'], port);
    else
      throw result['error'];
  }

  @override
  noSuchMethod(Invocation invocation) {
    return invoke(invocation.positionalArguments);
  }
}

dynamic _encodeData(dynamic data, {Map<dynamic, dynamic> cache}) {
  if (cache == null) cache = Map();
  if (cache.containsKey(data)) return cache[data];
  if (data is List) {
    var ret = [];
    cache[data] = ret;
    for (int i = 0; i < data.length; ++i) {
      ret.add(_encodeData(data[i], cache: cache));
    }
    return ret;
  }
  if (data is Map) {
    var ret = {};
    cache[data] = ret;
    for (var entry in data.entries) {
      ret[_encodeData(entry.key, cache: cache)] =
          _encodeData(entry.value, cache: cache);
    }
    return ret;
  }
  if (data is JSFunction) {
    return {
      '__js_function_ctx': data.ctx.address,
      '__js_function_val': data.val.address,
    };
  }
  if (data is IsolateJSFunction) {
    return {
      '__js_function_ctx': data.ctx,
      '__js_function_val': data.val,
    };
  }
  if (data is Future) {
    // Not support
    return {};
  }
  return data;
}

dynamic _decodeData(dynamic data, SendPort port,
    {Map<dynamic, dynamic> cache}) {
  if (cache == null) cache = Map();
  if (cache.containsKey(data)) return cache[data];
  if (data is List) {
    var ret = [];
    cache[data] = ret;
    for (int i = 0; i < data.length; ++i) {
      ret.add(_decodeData(data[i], port, cache: cache));
    }
    return ret;
  }
  if (data is Map) {
    if (data.containsKey('__js_function_val')) {
      int ctx = data['__js_function_ctx'];
      int val = data['__js_function_val'];
      if (port != null) {
        return IsolateJSFunction(ctx, val, port);
      } else {
        return JSFunction.fromAddress(ctx, val);
      }
    }
    var ret = {};
    cache[data] = ret;
    for (var entry in data.entries) {
      ret[_decodeData(entry.key, port, cache: cache)] =
          _decodeData(entry.value, port, cache: cache);
    }
    return ret;
  }
  return data;
}

void _runJsIsolate(Map spawnMessage) async {
  var qjs = FlutterQjs();
  SendPort sendPort = spawnMessage['port'];
  JsMethodHandler methodHandler = spawnMessage['handler'];
  ReceivePort port = ReceivePort();
  sendPort.send(port.sendPort);
  qjs.setMethodHandler(methodHandler);
  qjs.setModuleHandler((name) {
    var ptr = allocate<Pointer<Utf8>>();
    ptr.value = Pointer.fromAddress(0);
    sendPort.send({
      'type': 'module',
      'name': name,
      'ptr': ptr.address,
    });
    while (ptr.value.address == 0) sleep(Duration.zero);
    if (ptr.value.address == -1) throw Exception("Module Not found");
    var ret = Utf8.fromUtf8(ptr.value);
    sendPort.send({
      'type': 'release',
      'ptr': ptr.value.address,
    });
    free(ptr);
    return ret;
  });
  qjs.dispatch();
  await for (var msg in port) {
    var data;
    SendPort msgPort = msg['port'];
    try {
      switch (msg['type']) {
        case 'evaluate':
          data = await qjs.evaluate(
            msg['command'],
            name: msg['name'],
            evalFlags: msg['flag'],
          );
          break;
        case 'call':
          data = JSFunction.fromAddress(
            msg['ctx'],
            msg['val'],
          ).invoke(_decodeData(msg['args'], null));
          break;
        case 'close':
          qjs.close();
          port.close();
          break;
      }
      if (msgPort != null)
        msgPort.send({
          'data': _encodeData(data),
        });
    } catch (e, stack) {
      if (msgPort != null)
        msgPort.send({
          'error': e.toString() + "\n" + stack.toString(),
        });
    }
  }
}

typedef JsAsyncModuleHandler = Future<String> Function(String name);
typedef JsIsolateSpawn = void Function(SendPort sendPort);

class IsolateQjs {
  Future<SendPort> _sendPort;
  JsMethodHandler _methodHandler;
  JsAsyncModuleHandler _moduleHandler;

  /// Set a handler to manage js call with `channel(method, args)` function.
  /// The function must be a top-level function or a static method
  IsolateQjs(this._methodHandler);

  _ensureEngine() {
    if (_sendPort != null) return;
    ReceivePort port = ReceivePort();
    Isolate.spawn(
      _runJsIsolate,
      {
        'port': port.sendPort,
        'handler': _methodHandler,
      },
      errorsAreFatal: true,
    );
    var completer = Completer<SendPort>();
    port.listen((msg) async {
      if (msg is SendPort && !completer.isCompleted) {
        completer.complete(msg);
        return;
      }
      switch (msg['type']) {
        case 'module':
          var ptr = Pointer<Pointer>.fromAddress(msg['ptr']);
          try {
            ptr.value = Utf8.toUtf8(await _moduleHandler(msg['name']));
          } catch (e) {
            ptr.value = Pointer.fromAddress(-1);
          }
          break;
        case 'release':
          free(Pointer.fromAddress(msg['ptr']));
          break;
      }
    }, onDone: () {
      close();
      if (!completer.isCompleted) completer.completeError('isolate close');
    });
    _sendPort = completer.future;
  }

  /// Set a handler to manage js module.
  setModuleHandler(JsAsyncModuleHandler handler) {
    _moduleHandler = handler;
  }

  close() {
    if (_sendPort == null) return;
    _sendPort.then((sendPort) {
      sendPort.send({
        'type': 'close',
      });
    });
    _sendPort = null;
  }

  Future<dynamic> evaluate(String command, {String name, int evalFlags}) async {
    _ensureEngine();
    var evaluatePort = ReceivePort();
    var sendPort = await _sendPort;
    sendPort.send({
      'type': 'evaluate',
      'command': command,
      'name': name,
      'flag': evalFlags,
      'port': evaluatePort.sendPort,
    });
    var result = await evaluatePort.first;
    if (result['data'] != null)
      return _decodeData(result['data'], sendPort);
    else
      throw result['error'];
  }
}
