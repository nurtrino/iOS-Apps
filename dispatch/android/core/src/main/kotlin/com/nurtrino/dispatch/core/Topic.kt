package com.nurtrino.dispatch.core

/** The four parts of the app. A story belongs to exactly one. */
enum class Topic(val id: String, val title: String) {
    WAR("war", "War"),
    POLITICS("politics", "Politics"),
    ECONOMICS("economics", "Markets"),
    GAMING("gaming", "Gaming");

    companion object {
        /**
         * The topics the classifier is allowed to choose between.
         *
         * Gaming is excluded deliberately: no general news source publishes it,
         * so every gaming article comes from a source that only ever publishes
         * gaming, and letting the classifier pick it would only ever be a mistake.
         */
        val classifiable = listOf(WAR, POLITICS, ECONOMICS)

        fun from(id: String): Topic? = entries.firstOrNull { it.id == id }
    }
}
