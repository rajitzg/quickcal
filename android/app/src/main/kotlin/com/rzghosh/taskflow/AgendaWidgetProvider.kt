package com.rzghosh.taskflow

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Home screen agenda: the next few days of work sessions, deadlines and
 * calendar events. The Flutter app writes the rows (as JSON, under
 * "agenda") whenever its data changes and every ~30 minutes in the
 * background; this just draws them. Tapping anywhere opens the app.
 */
class AgendaWidgetProvider : HomeWidgetProvider() {
  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val openApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
    val updated = updatedLabel(widgetData)

    for (id in appWidgetIds) {
      val views = RemoteViews(context.packageName, R.layout.agenda_widget)

      // The list is filled by AgendaWidgetService. The data URI makes each
      // widget instance's intent distinct, as Android requires.
      val adapter =
          Intent(context, AgendaWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
          }
      @Suppress("DEPRECATION") views.setRemoteAdapter(R.id.agenda_list, adapter)
      views.setEmptyView(R.id.agenda_list, R.id.agenda_empty)

      views.setTextViewText(R.id.agenda_updated, updated)
      views.setOnClickPendingIntent(R.id.agenda_header, openApp)
      views.setOnClickPendingIntent(R.id.agenda_empty, openApp)
      views.setPendingIntentTemplate(R.id.agenda_list, listClickTemplate(context))

      appWidgetManager.updateAppWidget(id, views)
    }
    @Suppress("DEPRECATION")
    appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, R.id.agenda_list)
  }

  /** Rows are clickable through a template intent they fill in; it must be mutable. */
  private fun listClickTemplate(context: Context): PendingIntent {
    val intent =
        Intent(context, MainActivity::class.java).apply {
          action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
        }
    var flags = PendingIntent.FLAG_UPDATE_CURRENT
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
    return PendingIntent.getActivity(context, 1, intent, flags)
  }

  /** "Updated 3:05 PM", from when the app last wrote the agenda. */
  private fun updatedLabel(prefs: SharedPreferences): String {
    val generated = AgendaData.parse(prefs.getString("agenda", null))?.generated ?: return ""
    return try {
      val parsed =
          SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).parse(generated.take(19))
              ?: return ""
      "Updated " + DateFormat.getTimeInstance(DateFormat.SHORT).format(parsed)
    } catch (e: Exception) {
      ""
    }
  }
}
