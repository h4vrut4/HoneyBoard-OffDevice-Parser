Java.perform(function () {
  "use strict";

  var PREFIX = "[HB-OFFDEVICE] ";
  var MODEL_DIR = "/data/local/tmp/hb_offdevice/model";
  var LICENSE = "Samsung_nolimit_flow_parameter_morpheme_neural_cd27236b";

  function log(message) {
    console.log(PREFIX + message);
  }

  function composeCompatJamo(value) {
    var initials = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ";
    var medials = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ";
    var finals = ["", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"];
    var medialPairs = {
      "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ",
      "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"
    };
    var finalPairs = {
      "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ",
      "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ",
      "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"
    };
    var result = "";
    var index = 0;

    while (index < value.length) {
      var initialIndex = initials.indexOf(value[index]);
      if (initialIndex < 0 || index + 1 >= value.length || medials.indexOf(value[index + 1]) < 0) {
        result += value[index++];
        continue;
      }

      var medial = value[index + 1];
      var consumed = 2;
      if (index + consumed < value.length) {
        var combinedMedial = medialPairs[medial + value[index + consumed]];
        if (combinedMedial !== undefined) {
          medial = combinedMedial;
          consumed++;
        }
      }

      var final = "";
      if (index + consumed < value.length && finals.indexOf(value[index + consumed]) > 0) {
        var firstFinal = value[index + consumed];
        var afterFirst = index + consumed + 1;
        if (afterFirst >= value.length || medials.indexOf(value[afterFirst]) < 0) {
          final = firstFinal;
          consumed++;
          if (index + consumed < value.length) {
            var combinedFinal = finalPairs[final + value[index + consumed]];
            var afterSecond = index + consumed + 1;
            if (combinedFinal !== undefined &&
                (afterSecond >= value.length || medials.indexOf(value[afterSecond]) < 0)) {
              final = combinedFinal;
              consumed++;
            }
          }
        }
      }

      var medialIndex = medials.indexOf(medial);
      var finalIndex = finals.indexOf(final);
      result += String.fromCharCode(0xac00 + ((initialIndex * 21 + medialIndex) * 28) + finalIndex);
      index += consumed;
    }

    return result;
  }

  var originalLoader = Java.classFactory.loader;
  var session = null;
  var description = null;

  try {
    var ActivityThread = Java.use("android.app.ActivityThread");
    var application = ActivityThread.currentApplication();
    if (application === null) throw new Error("currentApplication() returned null");

    Java.classFactory.loader = application.getClassLoader();
    var Fluency = Java.use("com.microsoft.fluency.Fluency");
    var ModelSetDescription = Java.use("com.microsoft.fluency.ModelSetDescription");
    var ModelType = Java.use("com.microsoft.fluency.ModelSetDescription$Type");
    var Term = Java.use("com.microsoft.fluency.Term");
    var Map = Java.use("java.util.Map");
    var Entry = Java.use("java.util.Map$Entry");

    log("engine version=" + Fluency.getVersion());
    session = Fluency.createSession(LICENSE);
    if (session === null) throw new Error("Fluency.createSession() returned null");

    description = ModelSetDescription.dynamicWithFile.overload(
      "java.lang.String",
      "int",
      "[Ljava.lang.String;",
      "com.microsoft.fluency.ModelSetDescription$Type"
    ).call(
      ModelSetDescription,
      MODEL_DIR,
      4,
      Java.array("java.lang.String", []),
      ModelType.PRIMARY_DYNAMIC_MODEL.value
    );

    session.load(description);
    var map = Java.cast(session.getTrainer().getTermCounts(), Map);
    var iterator = map.entrySet().iterator();
    var rows = [];
    while (iterator.hasNext()) {
      var entry = Java.cast(iterator.next(), Entry);
      var term = Java.cast(entry.getKey(), Term);
      rows.push({
        term: composeCompatJamo(term.getTerm().toString()),
        count: entry.getValue().toString()
      });
    }
    rows.sort(function (left, right) {
      return left.term < right.term ? -1 : (left.term > right.term ? 1 : 0);
    });

    log("dynamic.lm entries=" + rows.length);
    rows.forEach(function (row, rowIndex) {
      log("term[" + rowIndex + "]=" + JSON.stringify(row.term) + "\tcount=" + row.count);
    });
    log("completed");
  } catch (error) {
    log("failed: " + error);
    if (error.stack) log(error.stack);
  } finally {
    if (session !== null && description !== null) {
      try {
        session.unload(description);
        log("model unloaded");
      } catch (unloadError) {
        log("unload failed: " + unloadError);
      }
    }
    Java.classFactory.loader = originalLoader;
  }
});
