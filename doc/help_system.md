# Entwicklerdokumentation kivitendo-Hilfesystem

Im Layout wird immer ein Hilfe-Link gerendert. Dieser öffnet ein Popupfenster und ruft darin die Action `Help/show` auf. Ihr wird eine Kontextinformation übergeben, mit der der Controller entscheiden kann, welche Hilfeseite angezeigt wird. Diese Kontextinformation wird automatisch aus dem aktuellen Controller und der aktuellen Action abgeleitet, kann aber im Controller überschrieben werden.

## Popup-Fenster

Hilfetexte werden in einem Popup-Fenster angezeigt. Das Link-Target für dieses Popup lautet `_kivitendo_help`.

## Kontextinformationen

Die Kontextinformationen werden normalerweise aus dem aktuellen Controller und der aktuellen Action erzeugt. Sie bestehen aus zwei Elementen, die durch einen `/` voneinander getrennt werden. Sie haben das Format `controller/action`.

Jedes Element der Kontextinformationen darf dabei nur aus den folgenden Zeichen bestehen:

* Buchstaben `a-z` und `A-Z`
* Ziffern `0-9`
* Die Zeichen `_` und `-`

### Speichern des aktuellen Controllers und der aktuellen Action

Um Kontextinformationen automatisch erzeugen zu können, wird bei jedem Aufruf der aktuelle Controller und die aktuelle Action im globalen Objekt `$::request` in den Methoden `controller` bzw. `action` gespeichert.

Die Methode `controller` enthält dabei nur den Basisnamen des Controllers, beispielsweise `BackgroundJob` für neuen Controller-Stil (Datei `SL/Controller/BackgroundJob.pm`) bzw. `oe` für alten Code (Datei `bin/mozilla/oe.pl`).

Die Action enthält ebenfalls nur den Basisnamen für neue Controller (also z.B. `show`, wenn im Controller `action_show` aufgerufen wird) bzw. den bereits rückübersetzen Namen für alte Controller (z.B. `update`, wenn im Rechnungs-Controller der Button mit der Beschriftung `Erneuern` gedrückt wurde). Falls bei einem alten Controller der Dispatch-Mechanismus genutzt wird, so enthält `action` bereits den Namen der letztlich aufgerufenen Funktion und nicht `dispatcher`.

### Überschreiben von Kontextinformationen

Oftmals ist es erwünscht, dass mehrere Actions denselben Hilfetext erhalten. Typische Beispiele: die Funktionen `add`, `edit` und `update` sowie potenziell `save`, `create`, `update`. Hierfür kann eine Action den Hilfekontext manuell setzen. Das muss geschehen, bevor das Layout gerendert wird; de facto also vor dem ersten Aufruf von `$::form->header`.

Das Überschreiben unterscheidet sich für neue und alte Controller. Neue Controller definieren ihre Abweichungen deklarativ mit einem Aufruf analog zum Folgenden:

    package SL::Controller::SomeController;

    use parent qw(SL::Controller::Base);

    __PACKAGE__->override_help_contexts(
      new  => 'edit',               # Verlinkung auf aktuellen Controller
      list => 'BackgroundJob/edit', # Verlinkung auf anderen Controller
    );

Alte Controller müssen innerhalb ihrer Action den Kontext wie folgt setzen, damit die Hilfefunktion auf die Seite für den Controller `other_controller` und die Action `other_action` verlinkt:

    $::request->help_system->context("other_controller/other_action");

Alternativ kann bei beiden Arten von Controller mit symbolischen Links im Dateisystem gearbeitet werden, die auf die gewünschten Seiten verweisen.

### Deaktivieren des Hilfe-Links

Bei manchen Actions mag es gewünscht sein, den Hilfelink komplett zu verstecken. Dazu muss man den Hilfekontext mit einem leeren String überschreiben (`undef` funktioniert nicht):

    # Im Layout wird hiermit kein Hilfe-Link angezeigt:
    $::request->help_system->context("");

## Speicherort für Hilfeseiten und Dateinamen

Alle Hilfeseiten werden im Verzeichnisbaum `templates/webpages/help/content` abgelegt. Darunter gibt es eine klar strukturierte Hierarchie:

1. Die erste Ebene ist die Sprache. Hier wird das übliche Zwei-Buchstaben-Kürzel genutzt. Deutsche Hilfeseiten werden also im Unterbaum `de` abgelegt.
2. Die zweite Ebene entspricht dem Controllernamen.
3. Für jede Action existiert dann eine Datei, deren Name die Action zzgl. Endung `.mmd` ist.

Der vollständige Pfad für die deutsche Hilfeseite zur Seite zum Anlegen von Artikeln (Action `add` im Controller `ic`) lautet also `templates/webpages/help/content/de/ic/add.mmd`.

Allgemeine Hilfeseiten, die keiner Action zugeordnet sind, sind ebenfalls möglich. Deren Dateinamen müssen dabei mit einem Unterstrich beginnen, um einem potenziellen Namenskonflikt aus dem Weg zu gehen. Dabei nimmt der Namen `_index.mmd` eine besondere Bedeutung ein, die weiter Unten im Abschnitt über die Suchreihenfolge genauer erläutert wird.

**Achtung:** Das Basisverzeichnis `templates/webpages/help` ist nur für HTML-Vorlagen gedacht, die direkt vom Controller `Help` benutzt werden.

## Suchreihenfolge für Hilfeseiten

### Beschreibung der Reihenfolge

Der Hilfe-Controller zeigt nicht ausschließlich die zum Kontext gehörende Seite an, sondern auch allgemeinere, falls die exakt gewünschte Variante nicht gefunden wird. Die Suchreihenfolge sieht wie folgt aus (der erste Treffer gewinnt):

1. im Unterbaum der Benutzersprache: der exakte Dateiname
2. im Unterbaum der Benutzersprache: für den Controller die Datei `_index.mmd` als Übersichtsseite des Controllers
3. im Unterbaum der Sprache Deutsch: der exakte Dateiname
4. im Unterbaum der Sprache Deutsch: für den Controller die Datei `_index.mmd` als Übersichtsseite des Controllers
5. im Unterbaum der Benutzersprache die Datei `_index.mmd` als Startseite der kivitendo-Hilfe
6. im Unterbaum der Sprache Deutsch die Datei `_index.mmd` als Startseite der kivitendo-Hilfe

Wird keine dieser Dateien gefunden, so wird eine Fehlermeldung ausgegeben. Da eine deutsche Hilfe-Startseite mitgeliefert wird, sollte das aber nie passieren.

### Beispiel

Wenn eine Benutzerin mit englischer Oberflächensprache die Hilfe im Controller `CustomerVendor` bei Action `edit` aufruft, so werden also nacheinander die folgenden Dateien gesucht (die Ziffern entsprechen den oben genannten Nummern):

1. `templates/webpages/content/en/CustomerVendor/edit.mmd`
2. `templates/webpages/content/en/CustomerVendor/_index.mmd`
3. `templates/webpages/content/de/CustomerVendor/edit.mmd`
4. `templates/webpages/content/de/CustomerVendor/_index.mmd`
5. `templates/webpages/content/en/_index.mmd`
6. `templates/webpages/content/de/_index.mmd`

## Layout und Styling

### Layoutsystem

Aktuell werden Hilfeseiten ohne das kivitendo-übliche Layout (Kopfzeile, Menüsystem) gerendert.

### Styling

Das Styling kann über CSS geregelt werden. Zusätzlich zum von der BenutzerIn ausgewählten Stylesheet wird die CSS-Datei `help.css` eingebunden, die bereits in minimaler Version existiert.

In der Hilfe-Ausgabe selber besitzt das `<body>`-Element die CSS-Klasse `kivitendo-help`. Darüber können CSS-Regeln alle Elemente greifen.

## Einfache Hilfe-Links

Links auf andere Hilfe-Texte können wie andere Links auch angegeben werden. Um die Verlinkung zu erleichtern, wird als Link-Ziel die folgende Syntax unterstützt: `help:WANTED_CONTROLLER/WANTED_ACTION`

## Zukünftige Erweiterungsmöglichkeiten

### Kommentare von BenutzerInnen

Ursprünglich wurde überlegt, die Dokumentation selber von allen BenutzerInnen bearbeitbar zu haben. Dies ist mit der aktuellen Implementation nicht mehr geplant. Es wäre aber möglich, Kommentare von BenutzerInnen zuzulassen, ähnlich wie es auch Seiten wie z.B. [PostgreSQL](http://www.postgresql.org/docs/9.5/interactive/index.html) machen. Folgendes Modell wäre eine Möglichkeit:

* Angemeldete BenutzerInnen bekommen eine Kommentar-Form mit Vorschau-Funktion, in der ebenfalls mit Markdown Sachen eingegeben werden können.
* Die Kommentare werden in der Datenbank gespeichert und mit der BenutzerIn verknüpft.
* BenutzerInnen können eigene Kommentare immer editieren und löschen.
* Über ein zusätzliches Gruppenrecht kann weiteren BenutzerInnen das Recht gewährt werden, Kommentare beliebiger BenutzerInnen zu bearbeiten oder zu löschen (Moderatorfunktion).

### Seitenindizierung

Eine Indizierung würde ermöglichen, Übersichtsseiten zu erzeugen, die automatisch auf alle vorhandenen Seiten oder z.B. nur alle Unterseiten eines Controllers zu verlinken. Das kann entweder statisch über ein Script geschehen (analog dazu, wie die Übersetzungen mit `locales.pl` erzeugt werden), oder aber zur Laufzeit durch spezielle Methoden im Controller `Help`. Letztere sollten zwecks Performance gecachet werden.

### Suchfunktionen

Eine Suchfunktion über die komplette Hilfe wäre hilfreich. Hierzu müsste aber, ähnlich wie bei der Seitenindizierung, ein Volltextindex gebaut werden. Dafür gibt es Produkte, die sich nur darum kümmern (z.B. [Sphinx](http://sphinxsearch.com/), [Solr](http://lucene.apache.org/solr/) oder [Elasticsearch](https://github.com/elastic/elasticsearch)).

### Unterstützung weiterer Markdown-Syntax-Varianten

Hier ist das Perl-Modul `Text::MultiMarkdown` zu erweitern. Mindestens die folgenden Funktionen werden bisher noch nicht unterstützt bzw. sind noch ungetestet:

* Markierung wichtiger Blöcke, die gesondert vom Rest des Texts abgehoben werden; eine Syntax dafür ist das Einschließen in `== … ==`
* Einbinden von Bildern
* Workflow-Abbildung

### Auto-Verlinking für Artikel in anderen Sprachen

Falls mal wirklich Hilfetexte in anderen Sprachen geschrieben werden, so könnte man den Mechanismus anpassen, der nicht existierende Seiten behandelt. Existiert eine Seite in der Benutzersprache nicht aber in anderen Sprachen, so könnte dies angezeigt und der BenutzerIn die Möglichkeit gegeben werden, diesen Artikel in anderen Sprachen anzuzeigen.

Das könnte auch für existierende Artikel gemacht werden. Solche Sprachverlinkung sollte automaisch erfolgen.

### Automatische Inhaltsverzeichnisse

Beim Anzeigen einer Seite könnte automatisch ein Inhaltsverzeichnis aus allen Überschriften erstellt und oben angezeigt werden. Viele Wiki-Systeme haben z.B. so eine Funktion.
