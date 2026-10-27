package com.rzghosh.taskflow

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/** One line of the agenda, as written by lib/home_widget/agenda.dart. */
data class AgendaRow(
    val kind: String,
    val title: String,
    val time: String,
    val color: Int,
    val overdue: Boolean,
)

class AgendaData(val generated: String?, val rows: List<AgendaRow>) {
  companion object {
    fun parse(json: String?): AgendaData? {
      if (json.isNullOrEmpty()) return null
      return try {
        val root = JSONObject(json)
        val list = root.optJSONArray("rows")
        val rows =
            (0 until (list?.length() ?: 0)).map { i ->
              val r = list!!.getJSONObject(i)
              AgendaRow(
                  kind = r.optString("kind"),
                  title = r.optString("title"),
                  time = r.optString("time"),
                  // Dart sends ARGB as a (possibly > Int.MAX) number.
                  color = r.optLong("color").toInt(),
                  overdue = r.optBoolean("overdue"),
              )
            }
        AgendaData(root.optString("generated", null), rows)
      } catch (e: Exception) {
        null
      }
    }
  }
}

class AgendaWidgetService : RemoteViewsService() {
  override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
      AgendaFactory(applicationContext)
}

private class AgendaFactory(private val context: Context) :
    RemoteViewsService.RemoteViewsFactory {
  private var rows: List<AgendaRow> = emptyList()

  override fun onCreate() {}

  override fun onDataSetChanged() {
    val json = HomeWidgetPlugin.getData(context).getString("agenda", null)
    rows = AgendaData.parse(json)?.rows ?: emptyList()
  }

  override fun onDestroy() {}

  override fun getCount(): Int = rows.size

  override fun getViewAt(position: Int): RemoteViews {
    val row = rows.getOrNull(position) ?: return RemoteViews(context.packageName, R.layout.agenda_widget_day)
    if (row.kind == "day") {
      return RemoteViews(context.packageName, R.layout.agenda_widget_day).apply {
        setTextViewText(R.id.day_title, row.title)
      }
    }
    return RemoteViews(context.packageName, R.layout.agenda_widget_item).apply {
      setTextViewText(R.id.item_title, row.title)
      if (row.kind == "empty") {
        setViewVisibility(R.id.item_bar, View.INVISIBLE)
        setViewVisibility(R.id.item_time, View.GONE)
      } else {
        setViewVisibility(R.id.item_bar, View.VISIBLE)
        setInt(R.id.item_bar, "setColorFilter", row.color)
        setViewVisibility(R.id.item_time, if (row.time.isEmpty()) View.GONE else View.VISIBLE)
        setTextViewText(R.id.item_time, row.time)
        // Set every time: list rows are reused, so a red "Overdue" would
        // otherwise stick to whichever row reuses this view.
        setTextColor(
            R.id.item_time,
            if (row.overdue) Color.parseColor("#E5484D")
            else context.getColor(R.color.widget_muted),
        )
      }
      // Opens the app through the list's click template.
      setOnClickFillInIntent(R.id.item_root, Intent())
    }
  }

  override fun getLoadingView(): RemoteViews? = null

  override fun getViewTypeCount(): Int = 2

  override fun getItemId(position: Int): Long = position.toLong()

  override fun hasStableIds(): Boolean = false
}
