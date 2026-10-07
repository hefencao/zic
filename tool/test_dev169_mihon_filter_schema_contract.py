#!/usr/bin/env python3
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

catalog = read('packages/catalog/lib/src/source_catalog.dart')
cached = read('packages/catalog/lib/src/cached_comic_source.dart')
adapter = read('packages/plugin_host/lib/src/runtime_source_adapter.dart')
protocol = read('packages/plugin_host/lib/src/runtime_protocol.dart')
driver = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt')
codec = read('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonFilterCodec.kt')
source = read('apps/app/lib/source_browser.dart')
source_test = read('apps/app/test/source_browser_test.dart')

for token in (
    'enum SourceSearchFilterKind',
    'header,', 'separator,', 'select,', 'text,', 'checkBox,', 'triState,', 'group,', 'sort,',
    'final class SourceSearchFilterNode',
    'typedef SourceSearchFilterState = Map<String, Object?>;',
    'Future<List<SourceSearchFilterNode>> loadSearchFilters();',
):
    require(catalog, token, 'typed source filter schema')
for token in ('supportsSearchFilters', 'SourceSearchFilterOption', 'selectedFilterIds'):
    forbid(catalog + cached + adapter + source, token, 'flat/capability filter contract')
for token in ("'filterState': Map<String, Object?>.from(filterState)", '_isSearchFilterState'):
    require(protocol + adapter, token, 'typed filter runtime protocol')
forbid(protocol + adapter + driver, 'filterIds', 'flat filter ID protocol')
for token in (
    'MihonFilterCodec.describe',
    'MihonFilterCodec.apply',
    'source.javaClass.classLoader',
):
    require(driver, token, 'Mihon driver filter delegation')
for token in (
    'header = type("$base\\$Header")',
    'separator = type("$base\\$Separator")',
    'select = type("$base\\$Select")',
    'text = type("$base\\$Text")',
    'checkBox = type("$base\\$CheckBox")',
    'triState = type("$base\\$TriState")',
    'group = type("$base\\$Group")',
    'sort = type("$base\\$Sort")',
    'sortSelection = type("$base\\$Sort\\$Selection")',
    'this?.isInstance(value) == true',
):
    require(codec, token, 'Mihon Filter base-class ABI')
forbid(codec, 'simpleName', 'concrete subclass-name filter detection')
for token in (
    'if (_searchFilters.isEmpty) return;',
    'if (_sections.length > 1 || _searchFilters.isNotEmpty)',
    'SourceSearchFilterKind.text',
    'SourceSearchFilterKind.sort',
    'SourceSearchFilterKind.group',
    "child: const Text('恢复默认')",
):
    require(source, token, 'source-owned filter presentation')
for token in (
    'empty source filter schema does not invent a filter category',
    'SourceSearchFilterKind.checkBox',
    'SourceSearchFilterKind.select',
    'SourceSearchFilterKind.sort',
    'SourceSearchFilterKind.text',
    "expect(native.lastFilterState['status'], isTrue);",
):
    require(source_test, token, 'filter widget contract')

kotlinc = shutil.which('kotlinc')
java = shutil.which('java')
if kotlinc and java:
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        filter_stub = temp / 'Filter.kt'
        smoke = temp / 'Smoke.kt'
        jar = temp / 'filter-codec.jar'
        filter_stub.write_text(r'''
package eu.kanade.tachiyomi.source.model
sealed class Filter<T>(val name: String, var state: T) {
  open class Header(name:String): Filter<Int>(name,0)
  open class Separator(name:String=""): Filter<Int>(name,0)
  abstract class Select<T>(name:String, val values:Array<T>, state:Int=0): Filter<Int>(name,state)
  abstract class Text(name:String, state:String=""): Filter<String>(name,state)
  abstract class CheckBox(name:String,state:Boolean=false): Filter<Boolean>(name,state)
  abstract class TriState(name:String,state:Int=0): Filter<Int>(name,state)
  abstract class Group<V>(name:String,state:List<V>): Filter<List<V>>(name,state)
  class Unknown(name:String): Filter<Int>(name,37)
  abstract class Sort(name:String,val values:Array<String>,state:Selection?=null): Filter<Sort.Selection?>(name,state) {
    data class Selection(val index:Int,val ascending:Boolean)
  }
}
''', encoding='utf-8')
        smoke.write_text(r'''
package dev.zic.pluginhost
import eu.kanade.tachiyomi.source.model.Filter
class StatusFilter: Filter.Group<Filter<*>>("状态", listOf(object: Filter.Select<String>("状态", arrayOf("全部","连载中","已完结"),0){}, Filter.Unknown("不支持的子项")))
class OrderByFilter: Filter.Sort("排序", arrayOf("最新","热门"), Selection(0,true))
class ScopeFilter: Filter.Text("搜索范围", "")
class CategoryFilter: Filter.Select<String>("类型", arrayOf("全部","其他","同人"),0)
class FlagFilter: Filter.CheckBox("仅收藏", false)
class TagFilter: Filter.TriState("标签", 0)
fun main() {
  val filters: List<Any> = listOf(Filter.Header("搜索"), StatusFilter(), CategoryFilter(), OrderByFilter(), ScopeFilter(), FlagFilter(), TagFilter(), Filter.Separator(), Filter.Unknown("不支持的顶级项"))
  val schema = MihonFilterCodec.describe(filters, StatusFilter::class.java.classLoader)
  check(schema.map { it["kind"] } == listOf("header", "group", "select", "sort", "text", "checkBox", "triState", "separator")) { schema.toString() }
  val group = schema[1]["children"] as List<*>
  check((group.single() as Map<*,*>)["kind"] == "select")
  MihonFilterCodec.apply(filters, mapOf("1.0" to 2, "1.1" to "ignored", "2" to 1, "3" to mapOf("index" to 1, "ascending" to false), "4" to "标题", "5" to true, "6" to 2, "8" to "ignored"), StatusFilter::class.java.classLoader)
  check(((filters[1] as StatusFilter).state.first() as Filter.Select<*>).state == 2)
  check(((filters[1] as StatusFilter).state.last() as Filter.Unknown).state == 37)
  check((filters.last() as Filter.Unknown).state == 37)
  check((filters[2] as CategoryFilter).state == 1)
  check((filters[3] as OrderByFilter).state?.index == 1 && (filters[3] as OrderByFilter).state?.ascending == false)
  check((filters[4] as ScopeFilter).state == "标题")
  check((filters[5] as FlagFilter).state)
  check((filters[6] as TagFilter).state == 2)
  println("MIHON_FILTER_CODEC_OK")
}
''', encoding='utf-8')
        subprocess.run([
            kotlinc,
            str(ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonFilterCodec.kt'),
            str(filter_stub),
            str(smoke),
            '-include-runtime', '-d', str(jar),
        ], check=True)
        result = subprocess.run([java, '-jar', str(jar)], check=True, capture_output=True, text=True)
        if 'MIHON_FILTER_CODEC_OK' not in result.stdout:
            raise SystemExit('Mihon filter codec smoke did not complete')
else:
    print('SKIP: kotlinc/java unavailable for Mihon Filter codec behavior')

version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', read('apps/app/pubspec.yaml'), re.M)
if version is None or int(version.group(1)) < 169:
    raise SystemExit('App build must be at least 169')
android = re.search(r'^versionCode=(\d+)\s*$', read('apps/app/android/zic-version.properties'), re.M)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode must match App build')

print('dev.169 Mihon source filter schema/state ownership: OK')
