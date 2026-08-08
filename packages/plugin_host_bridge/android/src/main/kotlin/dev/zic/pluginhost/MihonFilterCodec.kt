package dev.zic.pluginhost

import java.lang.reflect.Field

/**
 * Lossless bridge for Mihon's source-owned FilterList ABI.
 *
 * Extensions normally subclass Filter.Select/Group/Sort/etc. with source-
 * specific class names, so classification must use the Mihon base classes and
 * never concrete subclass-name heuristics.
 */
internal object MihonFilterCodec {
    private data class Types(
        val header: Class<*>?,
        val separator: Class<*>?,
        val select: Class<*>?,
        val text: Class<*>?,
        val checkBox: Class<*>?,
        val triState: Class<*>?,
        val group: Class<*>?,
        val sort: Class<*>?,
        val sortSelection: Class<*>?,
    )

    fun describe(filters: List<Any>, loader: ClassLoader): List<Map<String, Any?>> =
        describe(filters, loader, types(loader))

    fun apply(
        filters: List<Any>,
        filterState: Map<String, Any?>,
        loader: ClassLoader,
    ) {
        apply(filters, filterState, loader, types(loader))
    }

    private fun types(loader: ClassLoader): Types {
        fun type(name: String): Class<*>? = runCatching { loader.loadClass(name) }.getOrNull()
        val base = "eu.kanade.tachiyomi.source.model.Filter"
        return Types(
            header = type("$base\$Header"),
            separator = type("$base\$Separator"),
            select = type("$base\$Select"),
            text = type("$base\$Text"),
            checkBox = type("$base\$CheckBox"),
            triState = type("$base\$TriState"),
            group = type("$base\$Group"),
            sort = type("$base\$Sort"),
            sortSelection = type("$base\$Sort\$Selection"),
        )
    }

    private fun Class<*>?.matches(value: Any): Boolean = this?.isInstance(value) == true

    private fun describe(
        filters: List<Any>,
        loader: ClassLoader,
        types: Types,
        prefix: String = "",
    ): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        filters.forEachIndexed { index, filter ->
            val path = if (prefix.isEmpty()) "$index" else "$prefix.$index"
            val name = filter.readValue("name", "getName")?.toString()?.trim().orEmpty()
            when {
                types.header.matches(filter) -> result += mapOf(
                    "kind" to "header",
                    "filterId" to path,
                    "label" to name,
                )
                types.separator.matches(filter) -> result += mapOf(
                    "kind" to "separator",
                    "filterId" to path,
                    "label" to name,
                )
                types.group.matches(filter) -> result += mapOf(
                    "kind" to "group",
                    "filterId" to path,
                    "label" to name,
                    "children" to describe(
                        filter.readValue("state", "getState").asObjectList(),
                        loader,
                        types,
                        path,
                    ),
                )
                types.checkBox.matches(filter) -> result += mapOf(
                    "kind" to "checkBox",
                    "filterId" to path,
                    "label" to name,
                    "value" to (filter.readValue("state", "getState") as? Boolean ?: false),
                )
                types.triState.matches(filter) -> result += mapOf(
                    "kind" to "triState",
                    "filterId" to path,
                    "label" to name,
                    "value" to ((filter.readValue("state", "getState") as? Number)?.toInt() ?: 0),
                )
                types.select.matches(filter) -> result += mapOf(
                    "kind" to "select",
                    "filterId" to path,
                    "label" to name,
                    "options" to filter.readValue("values", "getValues")
                        .asObjectList()
                        .map { it.toString() },
                    "value" to ((filter.readValue("state", "getState") as? Number)?.toInt() ?: 0),
                )
                types.text.matches(filter) -> result += mapOf(
                    "kind" to "text",
                    "filterId" to path,
                    "label" to name,
                    "value" to (filter.readValue("state", "getState") as? String ?: ""),
                )
                types.sort.matches(filter) -> {
                    val selection = filter.readValue("state", "getState")
                    result += mapOf(
                        "kind" to "sort",
                        "filterId" to path,
                        "label" to name,
                        "options" to filter.readValue("values", "getValues")
                            .asObjectList()
                            .map { it.toString() },
                        "value" to selection?.let {
                            mapOf(
                                "index" to ((it.readValue("index", "getIndex") as? Number)?.toInt() ?: 0),
                                "ascending" to (it.readValue(
                                    "ascending",
                                    "getAscending",
                                    "isAscending",
                                ) as? Boolean ?: true),
                            )
                        },
                    )
                }
                else -> Unit
            }
        }
        return result
    }

    private fun apply(
        filters: List<Any>,
        filterState: Map<String, Any?>,
        loader: ClassLoader,
        types: Types,
        prefix: String = "",
    ) {
        filters.forEachIndexed { index, filter ->
            val path = if (prefix.isEmpty()) "$index" else "$prefix.$index"
            when {
                types.group.matches(filter) -> apply(
                    filter.readValue("state", "getState").asObjectList(),
                    filterState,
                    loader,
                    types,
                    path,
                )
                path !in filterState -> Unit
                types.checkBox.matches(filter) -> {
                    val value = filterState[path] as? Boolean
                        ?: error("Mihon CheckBox filter $path requires a boolean state")
                    filter.writeValue("state", value)
                }
                types.triState.matches(filter) -> {
                    val value = (filterState[path] as? Number)?.toInt()
                        ?: error("Mihon TriState filter $path requires an integer state")
                    require(value in 0..2) { "Mihon TriState filter $path state is invalid" }
                    filter.writeValue("state", value)
                }
                types.select.matches(filter) -> {
                    val value = (filterState[path] as? Number)?.toInt()
                        ?: error("Mihon Select filter $path requires an integer state")
                    val values = filter.readValue("values", "getValues").asObjectList()
                    require(value in values.indices) { "Mihon Select filter $path state is invalid" }
                    filter.writeValue("state", value)
                }
                types.text.matches(filter) -> {
                    val value = filterState[path] as? String
                        ?: error("Mihon Text filter $path requires a string state")
                    filter.writeValue("state", value)
                }
                types.sort.matches(filter) -> {
                    val raw = filterState[path]
                    if (raw == null) {
                        filter.writeValue("state", null)
                    } else {
                        val value = raw.asStringAnyMap("Mihon Sort filter $path")
                        val selectedIndex = (value["index"] as? Number)?.toInt()
                            ?: error("Mihon Sort filter $path requires an index")
                        val ascending = value["ascending"] as? Boolean
                            ?: error("Mihon Sort filter $path requires ascending state")
                        val values = filter.readValue("values", "getValues").asObjectList()
                        require(selectedIndex in values.indices) {
                            "Mihon Sort filter $path index is invalid"
                        }
                        val selectionType = types.sortSelection
                            ?: error("Mihon Sort.Selection ABI is unavailable")
                        val constructor = selectionType.constructors.firstOrNull { constructor ->
                            constructor.parameterCount == 2 &&
                                constructor.parameterTypes[0].boxed() == Integer::class.java &&
                                constructor.parameterTypes[1].boxed() == java.lang.Boolean::class.java
                        } ?: error("Mihon Sort.Selection constructor is unavailable")
                        constructor.isAccessible = true
                        filter.writeValue(
                            "state",
                            constructor.newInstance(selectedIndex, ascending),
                        )
                    }
                }
                else -> Unit
            }
        }
    }

    private fun Any?.asObjectList(): List<Any> = when (this) {
        null -> emptyList()
        is Iterable<*> -> filterNotNull()
        is Array<*> -> filterNotNull()
        else -> error("${javaClass.name} is not a filter list")
    }

    private fun Any?.asStringAnyMap(label: String): Map<String, Any?> {
        val map = this as? Map<*, *> ?: error("$label must be a map")
        require(map.keys.all { it is String && it.isNotEmpty() }) {
            "$label contains an invalid key"
        }
        @Suppress("UNCHECKED_CAST")
        return map as Map<String, Any?>
    }

    private fun Any.readValue(vararg names: String): Any? {
        for (name in names) {
            javaClass.methods.firstOrNull { method ->
                method.parameterCount == 0 && method.name.equals(name, ignoreCase = true)
            }?.let { method ->
                return runCatching { method.invoke(this) }.getOrNull()
            }
            findField(name)?.let { field ->
                return runCatching { field.get(this) }.getOrNull()
            }
        }
        return null
    }

    private fun Any.writeValue(name: String, value: Any?) {
        val setter = "set" + name.replaceFirstChar { it.uppercase() }
        javaClass.methods.firstOrNull { method ->
            method.parameterCount == 1 && method.name.equals(setter, ignoreCase = true)
        }?.let { method ->
            method.invoke(this, value.convertFor(method.parameterTypes[0]))
            return
        }
        val field = findField(name) ?: error("${javaClass.name} has no writable $name")
        field.set(this, value.convertFor(field.type))
    }

    private fun Any.findField(name: String): Field? {
        var type: Class<*>? = javaClass
        while (type != null) {
            val current = type
            runCatching { current.getDeclaredField(name) }.getOrNull()?.let { field ->
                field.isAccessible = true
                return field
            }
            type = current.superclass
        }
        return null
    }

    private fun Any?.convertFor(type: Class<*>): Any? = when {
        this == null -> null
        type == java.lang.Integer.TYPE || type == Integer::class.java -> (this as? Number)?.toInt()
        type == java.lang.Boolean.TYPE || type == java.lang.Boolean::class.java -> this as? Boolean
        else -> this
    }

    private fun Class<*>.boxed(): Class<*> = when (this) {
        java.lang.Integer.TYPE -> Integer::class.java
        java.lang.Boolean.TYPE -> java.lang.Boolean::class.java
        else -> this
    }
}
