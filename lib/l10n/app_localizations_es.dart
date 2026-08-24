// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppL10nEs extends AppL10n {
  AppL10nEs([String locale = 'es']) : super(locale);

  @override
  String get appName => 'xVeil';

  @override
  String get actionContinue => 'Continuar';

  @override
  String get actionBack => 'Atrás';

  @override
  String get actionCancel => 'Cancelar';

  @override
  String get actionDone => 'Listo';

  @override
  String get actionCopy => 'Copiar';

  @override
  String get actionRemove => 'Quitar';

  @override
  String get preparingTitle => 'Configurando tu nodo';

  @override
  String get preparingBody =>
      'Preparando tu identidad en este dispositivo. Puede tardar un poco: espera, por favor.';

  @override
  String get preparingFirstRunTitle => 'Creando esta identidad';

  @override
  String get preparingFirstRunBody =>
      'Una configuración única que puede tardar hasta un minuto (una prueba de trabajo que hace difícil falsificar la identidad). Solo ocurre la primera vez: cambiar a ella más adelante es instantáneo.';

  @override
  String get preparingUnlockTitle => 'Abriendo tu contenedor';

  @override
  String get preparingUnlockBody =>
      'Derivando tu clave y descifrando en este dispositivo. Es lento a propósito, para resistir los intentos de adivinar la contraseña. Espera un momento.';

  @override
  String get onboardWelcomeTitle => 'Te damos la bienvenida a xVeil';

  @override
  String get onboardWelcomeBody =>
      'Un mensajero descentralizado y resistente a la censura. Sin número de teléfono. Sin servidor central. Tu identidad y tus mensajes se quedan contigo.';

  @override
  String get onboardChooseTitle => 'Configura tu identidad';

  @override
  String get onboardCreateIdentity => 'Crear una identidad nueva';

  @override
  String get onboardCreateIdentitySub =>
      'Genera una clave soberana nueva en este dispositivo';

  @override
  String get onboardRestoreIdentity => 'Restaurar con la frase de recuperación';

  @override
  String get onboardRestoreIdentitySub =>
      'Usa tu frase de 24 palabras para recuperar una identidad existente';

  @override
  String get onboardRestoreBody =>
      'Introduce la frase de recuperación de 24 palabras que anotaste al crear la identidad. Se recreará la misma identidad en este dispositivo.';

  @override
  String get onboardRestoreSubmit => 'Restaurar';

  @override
  String get onboardLinkDevice => 'Vincular a un dispositivo que ya usas';

  @override
  String get onboardLinkDeviceSub =>
      'Sin frase de recuperación: aprueba este dispositivo desde el que ya tienes';

  @override
  String get onboardLinkDeviceBody =>
      'Este dispositivo recibe una identidad temporal propia para poder llegar a la red. En cuanto lo apruebes desde tu dispositivo actual, se une a tu identidad y la temporal deja de importar. Guarda tu frase de recuperación donde está: aquí no se te pedirá.';

  @override
  String get onboardSetupFailed =>
      'No se pudo crear el contenedor cifrado. Comprueba que haya espacio libre en el dispositivo e inténtalo de nuevo.';

  @override
  String get sshConfirmHostTitle => '¿Es este el servidor correcto?';

  @override
  String sshConfirmHostBody(Object host) {
    return 'Esta es la primera conexión con $host, así que todavía no hay nada con lo que comparar su identidad. Comprueba la huella de abajo con la que muestra el servidor, en el propio servidor y no a través de esta conexión. Si no coinciden, alguien está en medio.';
  }

  @override
  String get sshConfirmHostHint =>
      'Ejecuta esto en el servidor: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub';

  @override
  String get sshConfirmHostAccept => 'Coincide, continuar';

  @override
  String get sshHostNotConfirmed =>
      'Conexión cancelada: no se confirmó la identidad del servidor.';

  @override
  String get storageUnavailableTitle =>
      'El almacenamiento seguro no está disponible';

  @override
  String get storageUnavailableBody =>
      'xVeil no pudo cargar el componente que cifra todo lo que guarda. No se iniciará sin él: continuar significaría una contraseña que no protege nada y datos que desaparecen al cerrar la aplicación.';

  @override
  String get storageUnavailableAction =>
      'Esta versión está dañada o incompleta. Instala xVeil de nuevo desde la página de descargas. Nada de lo que ya estaba guardado en este dispositivo se ha tocado.';

  @override
  String get startupFailedTitle => 'xVeil no pudo iniciarse';

  @override
  String get startupFailedBody =>
      'Algo falló mientras la aplicación se preparaba, antes de tocar ninguno de tus datos. No se abrió nada, no se escribió nada y no se envió nada.';

  @override
  String get startupFailedAction =>
      'Cierra xVeil y vuelve a abrirlo. Si sigue ocurriendo, reinstálalo desde la página de descargas.';

  @override
  String get recoveryTitle => 'Guarda tu frase de recuperación';

  @override
  String get recoveryBody =>
      'Estas 24 palabras SON tu identidad. Quien las tenga la controla; si las pierdes, se pierde para siempre. Escríbelas en papel y guárdalas en un lugar seguro. Nunca las guardes en internet ni les hagas una foto.';

  @override
  String get recoveryNumbered =>
      'Las palabras están numeradas del 1 al 24. No continúes hasta haber anotado la número 24.';

  @override
  String get recoveryConfirm =>
      'He anotado las 24 palabras, hasta la número 24';

  @override
  String get recoveryPlaceholderWarning =>
      'Estas palabras son de RELLENO. El generador de identidades no está disponible en esta versión, así que la identidad se está creando al azar y estas palabras no restauran nada. No las anotes como copia de seguridad.';

  @override
  String get storageTitle => '¿Cómo quieres guardar tus datos?';

  @override
  String get storageHiddenTitle => 'Espacio oculto (recomendado)';

  @override
  String get storageHiddenBody =>
      'Tus chats y tus claves viven en un contenedor cifrado con negación plausible. Un adversario que se apodere de tu dispositivo no puede demostrar siquiera que los datos existen.';

  @override
  String get storagePlainTitle => 'Almacenamiento normal';

  @override
  String get storagePlainBody =>
      'Más rápido de configurar, pero la existencia de tus datos queda a la vista de cualquiera que inspeccione el dispositivo.';

  @override
  String get storagePlainWarning =>
      'No recomendado para personas en riesgo alto. Elige esto solo si la negación plausible no te preocupa.';

  @override
  String get lockTitle => 'Desbloquear xVeil';

  @override
  String get lockPasswordHint => 'Introduce tu contraseña';

  @override
  String get lockUnlock => 'Desbloquear';

  @override
  String get lockWrong => 'Contraseña incorrecta';

  @override
  String get lockTeardownIncomplete =>
      'El bloqueo no se completó: un nodo o túnel VPN puede seguir activo hasta cerrar la app por completo. Ciérrala y vuelve a abrirla para asegurarte.';

  @override
  String get lockStartOver => 'Empezar de cero';

  @override
  String get lockStartOverBody =>
      'Configura una identidad nueva en este dispositivo. Tus datos actuales no se borran, pero necesitarás su contraseña para volver a ellos. ¿Continuar?';

  @override
  String get lockWipe => 'Borrar todos los datos';

  @override
  String get lockWipeBody =>
      'Esto elimina de forma permanente el contenedor y TODAS las identidades que hay dentro, incluidas las ocultas o señuelo. No se puede deshacer: sin el contenedor los datos son irrecuperables, incluso con la contraseña correcta.';

  @override
  String get lockWipeTypePrompt =>
      'Para confirmar el borrado permanente, escribe esta frase exactamente:';

  @override
  String get lockWipePhrase => 'Entiendo las consecuencias';

  @override
  String get lockWipeConfirm => 'Borrar para siempre';

  @override
  String get lockWipeLeftTitle =>
      'Parte de los datos sigue en este dispositivo';

  @override
  String get lockWipeLeftContainer =>
      'No se ha podido borrar el contenedor y sigue en este dispositivo.';

  @override
  String get lockWipeLeftFiles =>
      'No se han podido borrar los archivos grandes guardados junto al contenedor y siguen en este dispositivo.';

  @override
  String get lockWipeLeftBoth =>
      'No se han podido borrar ni el contenedor ni los archivos grandes guardados junto a él, y ambos siguen en este dispositivo.';

  @override
  String get lockWipeLeftSpeechModel =>
      'No se ha podido borrar el modelo de voz descargado y sigue en este dispositivo.';

  @override
  String get lockWipeLeftSpeechModelUnknown =>
      'No se pudo comprobar el modelo de voz: este dispositivo no indicó dónde se guarda.';

  @override
  String get lockWipeLeftTranslationsUnknown =>
      'No se pudieron comprobar los modelos de traducción: este dispositivo no indicó dónde se guardan.';

  @override
  String get lockWipeLeftTranslations =>
      'No se han podido borrar los idiomas de traducción descargados, y sus nombres siguen en este dispositivo.';

  @override
  String get lockWipeLeftRest =>
      'Todo lo demás se ha destruido. Vuelve a intentarlo; si sigue sin conseguirlo, es que algo más de este equipo lo está reteniendo, como una herramienta de copias de seguridad o un disco de solo lectura.';

  @override
  String get lockWipeStopped =>
      'El borrado se ha interrumpido a medias, así que parte de tus datos puede seguir en este dispositivo. Vuelve a intentarlo.';

  @override
  String get lockWipeRetry => 'Volver a intentarlo';

  @override
  String get navChats => 'Chats';

  @override
  String get navCommunities => 'Comunidades';

  @override
  String get navFeed => 'Novedades';

  @override
  String get navNetwork => 'Red';

  @override
  String get navSettings => 'Ajustes';

  @override
  String get navCalls => 'Llamadas';

  @override
  String get callLogEmpty => 'Todavía no hay llamadas';

  @override
  String get callLogEmptyHint =>
      'Las llamadas que hagas y recibas en cualquiera de tus dispositivos aparecerán aquí';

  @override
  String get callOutcomeMissed => 'Perdida';

  @override
  String get callOutcomeDeclined => 'Rechazada';

  @override
  String get callOutcomeCancelled => 'Cancelada';

  @override
  String get callOutcomeBusy => 'Ocupado';

  @override
  String get callOutcomeFailed => 'Fallida';

  @override
  String get spaceCreateTitle => 'Nueva comunidad';

  @override
  String get spaceCreateAction => 'Crear';

  @override
  String get spaceNameHint => 'Nombre de la comunidad';

  @override
  String get spaceDescriptionLabel => 'Descripción';

  @override
  String get spaceDescriptionHint => 'Para qué es esta comunidad';

  @override
  String get spaceDescriptionEditTitle => 'Editar descripción';

  @override
  String get spaceProfileMediaTitle => 'Imágenes de la comunidad';

  @override
  String get spaceProfileMediaEmpty => 'Todavía no hay avatar ni portada';

  @override
  String get spaceProfileMediaSet =>
      'El avatar y la portada se comparten con los miembros';

  @override
  String get spaceAvatarChange => 'Cambiar avatar';

  @override
  String get spaceCoverChange => 'Cambiar portada';

  @override
  String get spaceProfileMediaClear => 'Quitar imágenes';

  @override
  String get spaceDescriptionSave => 'Guardar descripción';

  @override
  String get spaceVisibilityLabel => 'Visibilidad';

  @override
  String get spaceVisibilityPublic => 'Pública';

  @override
  String get spaceVisibilityPrivate => 'Privada';

  @override
  String get spaceVisibilitySecret => 'Secreta';

  @override
  String get spaceVisibilityPublicHint =>
      'Las publicaciones pueden compartirse públicamente. Si el descubrimiento está activado, el perfil autorizado y el canal público firmado pueden aparecer en la búsqueda verificada.';

  @override
  String get spaceVisibilityPrivateHint =>
      'Se entra por invitación y el contenido de la comunidad se cifra para los miembros actuales.';

  @override
  String get spaceVisibilitySecretHint =>
      'Las invitaciones ocultan el nombre de la comunidad; el contenido se cifra y la comunidad nunca aparece en las búsquedas.';

  @override
  String get spaceEmpty => 'Todavía no hay comunidades';

  @override
  String get spaceOperationFailed =>
      'No se pudo actualizar la comunidad. Comprueba la red e inténtalo de nuevo.';

  @override
  String get spaceChannelsEmpty => 'No hay canales en esta comunidad';

  @override
  String get spaceChannelCreateTitle => 'Nuevo canal';

  @override
  String get spaceChannelNameHint => 'Nombre del canal';

  @override
  String get spaceChannelDescriptionHint => 'Descripción (opcional)';

  @override
  String get spaceChannelKind => 'Tipo de canal';

  @override
  String get spaceChannelText => 'Canal de texto';

  @override
  String get spaceChannelVoice => 'Canal de voz';

  @override
  String get spaceChannelCategory => 'Categoría';

  @override
  String get spaceChannelCategoryLabel => 'Colocar en la categoría';

  @override
  String get spaceChannelNoCategory => 'Raíz de la comunidad';

  @override
  String get spaceChannelAccess => 'Acceso';

  @override
  String get spaceChannelAccessSpace => 'Todos los miembros de la comunidad';

  @override
  String get spaceChannelAccessRestricted =>
      'Restringido · al principio solo administradores';

  @override
  String get spaceChannelAccessSecret =>
      'Secreto · al principio solo administradores; TODAVÍA no está oculto: la protección es la misma que la de Restringido';

  @override
  String get spaceChannelHistory => 'Historial para los nuevos miembros';

  @override
  String get spaceChannelHistoryFromJoin => 'Solo desde que se unen';

  @override
  String get spaceChannelHistoryFull => 'Todo el historial del canal';

  @override
  String get spaceChannelHistorySinceNow => 'Los mensajes a partir de ahora';

  @override
  String get spaceChannelManage => 'Gestionar canal';

  @override
  String get spaceChannelEdit => 'Editar canal';

  @override
  String get spaceChannelSave => 'Guardar canal';

  @override
  String get spaceChannelArchive => 'Archivar canal';

  @override
  String get spaceChannelRestore => 'Restaurar canal';

  @override
  String get spaceChannelMakeDefault => 'Hacer canal predeterminado';

  @override
  String get spaceChannelArchived => 'Archivado';

  @override
  String get spaceChannelArchiveCategoryBlocked =>
      'Primero mueve o archiva los canales activos de esta categoría.';

  @override
  String get spaceVoiceStartFailed =>
      'No se pudo iniciar esta sesión de voz ni unirse a ella.';

  @override
  String get spacePostsTitle => 'Publicaciones';

  @override
  String get spacePostsEmpty => 'Todavía no hay publicaciones';

  @override
  String get spacePostCreateTitle => 'Nueva publicación';

  @override
  String get spacePostTitleHint => 'Título (opcional)';

  @override
  String get spacePostBodyHint => 'Comparte una novedad con la comunidad…';

  @override
  String get spacePostBlocks => 'Bloques';

  @override
  String get spacePostBlockParagraph => 'Párrafo';

  @override
  String get spacePostBlockHeading1 => 'Título grande';

  @override
  String get spacePostBlockHeading2 => 'Título mediano';

  @override
  String get spacePostBlockHeading3 => 'Título pequeño';

  @override
  String get spacePostBlockBulletList => 'Lista con viñetas';

  @override
  String get spacePostBlockOrderedList => 'Lista numerada';

  @override
  String get spacePostBlockCode => 'Bloque de código';

  @override
  String get spacePostBlockDivider => 'Separador';

  @override
  String get spacePostPreview => 'Vista previa de la publicación';

  @override
  String get spacePostContinueEditing => 'Seguir editando';

  @override
  String get spacePostPublish => 'Publicar';

  @override
  String get spacePostDraftHint =>
      'Guardado cifrado en este dispositivo. El borrador no se comparte hasta que lo publiques.';

  @override
  String get spacePostSchedule => 'Programar';

  @override
  String get spacePostScheduleClear => 'Publicar de inmediato';

  @override
  String get spacePostScheduleFuture => 'Elige un momento en el futuro.';

  @override
  String get spacePostScheduleDeviceHint =>
      'Cifrado en este dispositivo y no se comparte antes de la publicación. Si xVeil está cerrado o bloqueado a esa hora, se publicará tras el siguiente desbloqueo.';

  @override
  String get spacePostScheduledSuccess => 'Publicación programada';

  @override
  String get spacePostScheduledPublications => 'Publicaciones programadas';

  @override
  String get spacePostScheduledFailed =>
      'No se publicó. Revísala y reinténtalo o cancélala.';

  @override
  String get spacePostPublishNow => 'Publicar ahora';

  @override
  String get spacePostPublishedNow => 'Publicación publicada';

  @override
  String get spacePostCancelSchedule => 'Cancelar programación';

  @override
  String get spacePostCancelScheduleTitle =>
      '¿Cancelar la publicación programada?';

  @override
  String get spacePostCancelScheduleBody =>
      'Se eliminará la copia local cifrada de esta publicación programada.';

  @override
  String get spacePostScheduleCancelled => 'Publicación programada cancelada';

  @override
  String get spacePostMediaAttach => 'Añadir contenido o archivo';

  @override
  String get spacePostMediaRejected =>
      'No se pudieron adjuntar algunos archivos';

  @override
  String get spacePostRecordVoice => 'Grabar mensaje de voz';

  @override
  String get spacePostRecordShortVideo => 'Grabar vídeo corto';

  @override
  String get spacePostUseRecording => 'Usar la grabación';

  @override
  String get spacePostEdit => 'Editar publicación';

  @override
  String get spacePostEdited => 'Editada';

  @override
  String get spacePostPin => 'Fijar';

  @override
  String get spacePostUnpin => 'Dejar de fijar';

  @override
  String get spacePostPinned => 'Fijada';

  @override
  String get spacePostCommentsTitle => 'Comentarios';

  @override
  String get spacePostCommentsOpen => 'Abrir comentarios';

  @override
  String get spacePostCommentsEmpty => 'Todavía no hay comentarios';

  @override
  String get spacePostCommentsEmptyHint =>
      'Empieza un debate sobre esta publicación.';

  @override
  String spacePostCommentsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count comentarios',
      one: '1 comentario',
      zero: 'Sin comentarios',
    );
    return '$_temp0';
  }

  @override
  String get spacePostCommentHint => 'Escribe un comentario…';

  @override
  String get spacePostCommentSend => 'Enviar comentario';

  @override
  String get spacePostCommentReply => 'Responder';

  @override
  String get spacePostCommentEdit => 'Editar';

  @override
  String get spacePostCommentEditing => 'Editando el comentario';

  @override
  String get spacePostCommentCancelEdit => 'Cancelar la edición';

  @override
  String get spacePostCommentSaveEdit => 'Guardar cambios';

  @override
  String get spacePostCommentEdited => 'editado';

  @override
  String get spacePostCommentEditFailed =>
      'No se pudieron guardar los cambios del comentario';

  @override
  String get spacePostCommentDelete => 'Eliminar';

  @override
  String get spacePostCommentDeleteTitle => '¿Eliminar el comentario?';

  @override
  String get spacePostCommentDeleteBody =>
      'El comentario desaparecerá para los miembros y, si era público, también del canal público. Esto no se puede deshacer.';

  @override
  String get spaceModerationDeleteComment => 'Retirar comentario';

  @override
  String get spacePostCommentBlockAuthor => 'Bloquear al autor';

  @override
  String get spacePostCommentBlockAuthorTitle => '¿Bloquear a este autor?';

  @override
  String get spacePostCommentBlockAuthorBody =>
      'Sus publicaciones, comentarios, menciones y mensajes directos quedarán ocultos en esta identidad. No se le avisará.';

  @override
  String get spacePostCommentParentUnavailable =>
      'El comentario original se eliminó o está oculto';

  @override
  String spacePostCommentReplyingTo(String author) {
    return 'Respondiendo a $author';
  }

  @override
  String get spacePostCommentCancelReply => 'Cancelar la respuesta';

  @override
  String get spacePostCommentFailed => 'No se pudo publicar este comentario';

  @override
  String get spacePostCommentTooLong =>
      'El comentario es demasiado grande para cifrarlo y enviarlo.';

  @override
  String get spacePostCommentReadOnly => 'Este debate es de solo lectura.';

  @override
  String get spacePostCommentPublic => 'Visible en el canal público';

  @override
  String get spacePostCommentPublicHint =>
      'Crea una copia pública aparte, firmada por su autor. Quien no sea miembro podrá leerla.';

  @override
  String get spacePostPublicReaction => 'Añadir una reacción pública';

  @override
  String get spacePostPublicDiscussionReadOnly =>
      'Solo se muestran los comentarios y las reacciones que sus autores hicieron públicos de forma explícita.';

  @override
  String get feedPinnedTitle => 'Fijado';

  @override
  String get feedRecentTitle => 'Reciente';

  @override
  String get spacePostDelete => 'Eliminar publicación';

  @override
  String get spacePostDeleteTitle => '¿Eliminar esta publicación?';

  @override
  String get spacePostDeleteBody =>
      'Una lápida firmada la retirará del canal de la comunidad en todos los dispositivos sincronizados de los miembros. Esto no se puede deshacer.';

  @override
  String get spacePostTypePost => 'Publicación';

  @override
  String get spacePostTypeArticle => 'Artículo';

  @override
  String get spacePostTypeVideo => 'Vídeo';

  @override
  String get spacePostTypeShortVideo => 'Vídeo corto';

  @override
  String get spacePostTypeAudio => 'Audio';

  @override
  String get spacePostTypeVoiceMessage => 'Mensaje de voz';

  @override
  String get spaceFeedEnable => 'Mostrar esta comunidad en Novedades';

  @override
  String get spaceFeedDisable => 'Ocultar esta comunidad de Novedades';

  @override
  String get spaceSubscriptionSettings => 'Novedades y notificaciones';

  @override
  String get spaceFeedSetting => 'Publicaciones en Novedades';

  @override
  String get spaceFeedSettingHint =>
      'Esto cambia solo tus Novedades combinadas; sigues siendo miembro de la comunidad.';

  @override
  String get spaceNotificationsSetting => 'Notificaciones de publicaciones';

  @override
  String get spaceNotificationsSettingHint =>
      'Avisar en este dispositivo cuando llegue una publicación nueva de la comunidad.';

  @override
  String get spacePublicReadOnly => 'Suscripción pública · solo lectura';

  @override
  String get spacePublicSnapshotStale =>
      'Se muestra la última instantánea verificada. Para actualizarla hace falta un portador verificado accesible.';

  @override
  String get spacePublicUnsubscribe => 'Cancelar la suscripción';

  @override
  String get spacePublicUnsubscribeConfirm =>
      '¿Quitar de este dispositivo esta suscripción pública y su instantánea sin conexión?';

  @override
  String get spaceDiscoveryAction => 'Buscar comunidades públicas';

  @override
  String get spaceDiscoveryTitle => 'Buscar comunidades públicas';

  @override
  String get spaceDiscoveryHint => 'Nombre o node_id exacto';

  @override
  String get spaceDiscoveryIdle =>
      'Busca por nombre o pega un node_id exacto de una fuente de confianza.';

  @override
  String get spaceDiscoverySearching =>
      'Buscando comunidades públicas verificadas';

  @override
  String spaceDiscoveryResults(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count comunidades verificadas',
      one: '1 comunidad verificada',
    );
    return '$_temp0';
  }

  @override
  String get spaceDiscoveryNoVerifiedResults =>
      'Ninguna comunidad pública alcanzó el quórum de portadores verificados.';

  @override
  String get spaceDiscoveryUnavailable =>
      'La búsqueda pública no está disponible. Comprueba la conexión e inténtalo de nuevo.';

  @override
  String get spaceDiscoveryPartialQuorum =>
      'Se encontró un anuncio que coincide, pero todavía no tiene suficientes portadores verificados independientes.';

  @override
  String spaceDiscoveryPosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count publicaciones',
      one: '1 publicación',
      zero: 'Sin publicaciones',
    );
    return '$_temp0';
  }

  @override
  String spaceDiscoverySources(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fuentes verificadas',
      one: '1 fuente verificada',
    );
    return '$_temp0';
  }

  @override
  String get spacePublicSubscribe => 'Suscribirse';

  @override
  String get spaceCommentNotificationsSetting => 'Notificaciones de debates';

  @override
  String get spaceCommentNotificationsSettingHint =>
      'Elige qué comentarios nuevos avisan en este dispositivo.';

  @override
  String get spaceCommentNotificationsAll => 'Todos los comentarios';

  @override
  String get spaceCommentNotificationsReplies =>
      'Las respuestas a mí y los comentarios en mis publicaciones';

  @override
  String get spaceCommentNotificationsNone => 'Desactivadas';

  @override
  String get spaceHideRecommendationsSetting =>
      'No recomendarme esta comunidad';

  @override
  String get spaceHideRecommendationsSettingHint =>
      'Mantener esta comunidad fuera de las recomendaciones en este dispositivo.';

  @override
  String get spaceSettingsTitle => 'Miembros y ajustes';

  @override
  String get spaceMembersTooltip => 'Miembros y ajustes';

  @override
  String get spaceChannelRotateKey => 'Cambiar la clave';

  @override
  String get spaceChannelRotateKeyHint =>
      'Los mismos miembros, una clave nueva a partir de ahora';

  @override
  String get spaceChannelRotateKeyDone => 'El canal tiene una clave nueva';

  @override
  String get spaceRetentionTitle => 'Conservación del historial';

  @override
  String get spaceRetentionSafetyHint =>
      'La política de la comunidad y el historial local de este dispositivo son independientes.';

  @override
  String get spaceRetentionGlobal => 'Política de la comunidad';

  @override
  String get spaceRetentionGlobalHint =>
      'Firmada por la propietaria y aplicada por todos los miembros.';

  @override
  String get spaceRetentionLocal => 'En este dispositivo';

  @override
  String get spaceRetentionLocalHint =>
      'Solo oculta el historial local; nunca borra contenido para los demás miembros.';

  @override
  String get spaceRetentionMediaOnly => 'Eliminar solo el contenido multimedia';

  @override
  String get spaceRetentionMediaOnlyHint =>
      'Conserva el texto de los mensajes y las publicaciones, y caduca los adjuntos pasado el periodo elegido.';

  @override
  String get spaceRetentionMediaExpired =>
      'Contenido multimedia retirado por la política de conservación';

  @override
  String get spaceActiveTitle => 'La comunidad está activa';

  @override
  String get spaceActiveHint =>
      'Los miembros pueden publicar, escribir en los canales y entrar en las salas de voz.';

  @override
  String get spaceArchivedTitle => 'La comunidad está archivada';

  @override
  String get spaceArchivedHint =>
      'El historial se puede seguir leyendo, pero los mensajes, las publicaciones, las reacciones, las salas de voz y los ajustes son de solo lectura.';

  @override
  String get spaceDeletedTitle => 'La comunidad está pendiente de eliminación';

  @override
  String get spaceDeletedHint =>
      'El contenido está oculto y toda la actividad detenida. La propietaria puede restaurar la comunidad hasta que termine el periodo de recuperación.';

  @override
  String get spaceDeleteTitle => '¿Eliminar la comunidad?';

  @override
  String get spaceDeleteConfirm =>
      'La comunidad se podrá recuperar durante 7 días. Después, las copias locales cifradas se purgan en segundo plano y las instantáneas antiguas ya no pueden restaurarlas.';

  @override
  String get spaceDeleteAction => 'Eliminar comunidad';

  @override
  String get spaceDeleteHint =>
      'Inicia un periodo de recuperación de 7 días antes de la limpieza física.';

  @override
  String spaceRecoveryUntil(String date) {
    return 'La recuperación está disponible hasta el $date';
  }

  @override
  String get spaceArchiveTitle => '¿Archivar la comunidad?';

  @override
  String get spaceArchiveConfirm =>
      'Esto crea un límite firmado por la propietaria y deja la comunidad en solo lectura en todos los dispositivos. Podrás restaurarla más adelante.';

  @override
  String get spaceArchiveAction => 'Archivar';

  @override
  String get spaceRestoreTitle => '¿Restaurar la comunidad?';

  @override
  String get spaceRestoreConfirm =>
      'El contenido nuevo empezará en una época de ciclo de vida firmada y nueva. El historial archivado sigue disponible.';

  @override
  String get spaceRestoreAction => 'Restaurar';

  @override
  String spaceMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miembros',
      one: '1 miembro',
    );
    return '$_temp0';
  }

  @override
  String get spaceMemberAdd => 'Invitar a un miembro';

  @override
  String get spaceNoContactsToAdd =>
      'Todos los contactos aceptados ya son miembros';

  @override
  String get spaceInviteSent =>
      'Invitación enviada. La pertenencia y las claves siguen siendo privadas hasta que la acepten.';

  @override
  String get spaceInvitesTitle => 'Invitaciones';

  @override
  String get spaceSecretInviteTitle => 'Comunidad secreta';

  @override
  String spaceInviteFrom(String peer) {
    return 'De $peer';
  }

  @override
  String get spaceInviteAccept => 'Aceptar';

  @override
  String get spaceInviteDecline => 'Rechazar';

  @override
  String get spaceInviteJoining =>
      'Aceptada · esperando la pertenencia verificada';

  @override
  String get spaceJoinAction => 'Unirse con un enlace';

  @override
  String get spaceJoinDialogTitle => 'Solicitar entrar en una comunidad';

  @override
  String get spaceJoinCodeHint => 'Pega un enlace xveil://space';

  @override
  String get spaceJoinSafetyHint =>
      'El enlace solo envía una solicitud de pertenencia. Los canales, los miembros y las claves siguen sin estar disponibles hasta que un administrador la apruebe con una concesión firmada.';

  @override
  String get spaceJoinRequestSent =>
      'Solicitud enviada. La comunidad aparecerá tras la aprobación firmada.';

  @override
  String get spaceJoinRequestsTitle => 'Solicitudes de entrada';

  @override
  String spaceJoinRequestFrom(String peer) {
    return 'Solicitud de $peer';
  }

  @override
  String get spaceJoinRequestPending => 'Esperando aprobación';

  @override
  String get spaceJoinRequestApproved =>
      'Aprobada · recibiendo la pertenencia verificada';

  @override
  String get spaceJoinRequestDeclined => 'Rechazada';

  @override
  String get spaceMembershipStatusTitle => 'Estado de la pertenencia';

  @override
  String get spaceMembershipPending => 'Pertenencia pendiente';

  @override
  String get spaceMembershipActive => 'Miembro activo';

  @override
  String get spaceMembershipSuspended => 'Pertenencia suspendida';

  @override
  String spaceMembershipSuspendedUntil(String until) {
    return 'Pertenencia suspendida hasta el $until';
  }

  @override
  String get spaceMembershipLeft => 'Ya no es miembro';

  @override
  String get spaceMembershipBanned => 'Pertenencia vetada';

  @override
  String get spaceJoinDismiss => 'Descartar';

  @override
  String get spaceJoinApprove => 'Aprobar';

  @override
  String get spaceJoinDecline => 'Rechazar';

  @override
  String get spaceJoinLinkTitle => 'Enlace público para unirse';

  @override
  String get spaceJoinLinkHint =>
      'Cualquiera que tenga este enlace revocable puede solicitar la pertenencia. El enlace nunca concede acceso por sí solo.';

  @override
  String get spaceJoinLinkCreate => 'Crear enlace';

  @override
  String get spaceJoinLinkCopy => 'Copiar enlace';

  @override
  String get spaceJoinLinkRevoke => 'Revocar enlace';

  @override
  String get spaceJoinLinkCopied => 'Enlace para unirse copiado';

  @override
  String get spaceJoinLinkRevoked => 'Enlace para unirse revocado';

  @override
  String get spaceRecommendationsTitle => 'Recomendaciones';

  @override
  String get spaceRecommendationsHint =>
      'Crea una campaña pública firmada. Después los miembros podrán recomendar esta comunidad solo a los contactos que elijan de forma explícita.';

  @override
  String get spaceRecommendationCreate => 'Crear campaña';

  @override
  String get spaceRecommendationTextHint =>
      'Lo que los miembros pueden enviar junto con la tarjeta de la comunidad';

  @override
  String get spaceRecommendationShare => 'Recomendar la comunidad';

  @override
  String get spaceRecommendationSelectCampaign => 'Elige una campaña';

  @override
  String get spaceRecommendationSelectContact => 'Elige a quién enviarla';

  @override
  String get spaceRecommendationRevoke => 'Revocar campaña';

  @override
  String get spaceRecommendationSent => 'Recomendación enviada';

  @override
  String get spaceRecommendationDuplicate =>
      'Esta campaña ya se envió a ese contacto';

  @override
  String get spaceRecommendationRateLimited =>
      'Se alcanzó el límite de recomendaciones. Inténtalo más tarde.';

  @override
  String get spaceRecommendationAlreadyMember => 'Este contacto ya es miembro';

  @override
  String get spaceRecommendationEmpty =>
      'No hay campañas de recomendación activas';

  @override
  String get spaceRecommendationReceive => 'Recomendaciones de comunidades';

  @override
  String get spaceRecommendationReceiveHint =>
      'Permite que los contactos aceptados envíen tarjetas de comunidades. Si lo desactivas, las recomendaciones nuevas se descartan en silencio.';

  @override
  String get spaceRecommendationPolicyEnabled =>
      'Permitir recomendaciones de comunidades';

  @override
  String get spaceRecommendationPolicyDisabled =>
      'Recomendaciones de comunidades desactivadas';

  @override
  String get spaceRecommendationPolicyHint =>
      'Ajuste firmado para toda la comunidad. Los límites antispam son fijos y no se pueden debilitar.';

  @override
  String get spaceRecommendationSentAuditTitle => 'Recomendaciones enviadas';

  @override
  String get spaceRecommendationSentAuditHint =>
      'Registro local cifrado. Revocar retira la tarjeta elegida en ambos lados.';

  @override
  String get spaceRecommendationSentAuditEmpty =>
      'No se ha enviado ninguna recomendación desde este dispositivo';

  @override
  String spaceRecommendationSentTo(String recipient) {
    return 'Enviada a $recipient';
  }

  @override
  String get spaceRecommendationSentRevoked => 'revocada';

  @override
  String get spaceRecommendationSentRevoke =>
      'Revocar la recomendación enviada';

  @override
  String get spacePolicyAuditRecommendations => 'Política de recomendaciones';

  @override
  String get spaceRoleLabel => 'Rol en la comunidad';

  @override
  String get spaceRoleOwner => 'Propietaria';

  @override
  String get spaceRoleAdmin => 'Administrador';

  @override
  String get spaceRoleMember => 'Miembro';

  @override
  String get spaceAccessTitle => 'Roles y acceso';

  @override
  String get spaceAccessHint =>
      'Conjuntos de permisos reutilizables, grupos de participantes y roles asignados directamente. Cada cambio se firma y queda auditado.';

  @override
  String get spacePolicyAuditTitle => 'Auditoría de políticas';

  @override
  String get spacePolicyAuditHint =>
      'Cambios firmados de acceso y conservación. Las entradas no se pueden editar ni borrar.';

  @override
  String get spacePolicyAuditEmpty =>
      'Todavía no se ha firmado ningún cambio de política.';

  @override
  String get spacePolicyAuditAccess => 'Política de acceso';

  @override
  String get spacePolicyAuditRetention => 'Política de conservación';

  @override
  String spacePolicyAuditAccessSummary(
    int revision,
    int roles,
    int groups,
    int assignments,
  ) {
    return 'Revisión $revision · $roles roles · $groups grupos · $assignments asignaciones directas';
  }

  @override
  String spacePolicyAuditSignedBy(String author) {
    return 'Firmado por $author';
  }

  @override
  String get spacePolicyAuditScopeSpace => 'Toda la comunidad';

  @override
  String spacePolicyAuditScopeChannel(String channel) {
    return 'Canal $channel';
  }

  @override
  String get spacePolicyAuditRetentionInherit =>
      'hereda la política de la comunidad';

  @override
  String get spacePolicyAuditRetentionForever => 'conserva el historial';

  @override
  String get spacePolicyAuditMediaOnly => 'solo el contenido multimedia';

  @override
  String get spaceRecentActionsTitle => 'Acciones recientes';

  @override
  String get spaceRecentActionsHint =>
      'Historial administrativo firmado. Ves lo que permiten tus permisos.';

  @override
  String get spaceRecentActionsEmpty => 'Aquí todavía no se ha hecho nada.';

  @override
  String get spaceRecentActionsWithheld => 'Evento no disponible';

  @override
  String get spaceRecentActionsWithheldHint =>
      'Aquí ocurrió algo que tus permisos no alcanzan a ver.';

  @override
  String spaceRecentActionsBy(String author) {
    return 'por $author';
  }

  @override
  String spaceActionMemberAdded(String member) {
    return 'Añadió a $member';
  }

  @override
  String spaceActionMemberRemoved(String member) {
    return 'Expulsó a $member';
  }

  @override
  String spaceActionMemberLeft(String member) {
    return '$member se marchó';
  }

  @override
  String spaceActionRoleChanged(String member) {
    return 'Cambió el rol de $member';
  }

  @override
  String spaceActionOwnershipTransferred(String member) {
    return 'Cedió la propiedad a $member';
  }

  @override
  String spaceActionMemberMuted(String member) {
    return 'Silenció a $member';
  }

  @override
  String spaceActionMemberUnmuted(String member) {
    return 'Dejó de silenciar a $member';
  }

  @override
  String spaceActionMemberBanned(String member) {
    return 'Vetó a $member';
  }

  @override
  String spaceActionModerationApplied(String member) {
    return 'Moderó a $member';
  }

  @override
  String spaceActionModerationRevoked(String member) {
    return 'Levantó una medida de moderación sobre $member';
  }

  @override
  String get spaceActionChannelCreated => 'Creó un canal';

  @override
  String get spaceActionChannelUpdated => 'Modificó un canal';

  @override
  String get spaceActionSpaceRenamed => 'Cambió el nombre de la comunidad';

  @override
  String get spaceActionSpaceDescriptionChanged => 'Cambió la descripción';

  @override
  String get spaceActionSpaceProfileMediaChanged =>
      'Cambió el avatar o la portada';

  @override
  String get spaceActionRulesPublished => 'Publicó reglas nuevas';

  @override
  String spaceActionRulesAccepted(String member) {
    return '$member aceptó las reglas';
  }

  @override
  String get spaceActionAccessPolicyChanged => 'Cambió los roles y el acceso';

  @override
  String get spaceActionRetentionChanged =>
      'Cambió la política de conservación';

  @override
  String get spaceActionSpaceArchived => 'Archivó la comunidad';

  @override
  String get spaceActionSpaceDeleted => 'Eliminó la comunidad';

  @override
  String get spaceActionSpaceRestored => 'Restauró la comunidad';

  @override
  String get spaceActionPostPinChanged => 'Cambió la publicación fijada';

  @override
  String get spaceActionRecommendationCampaignChanged =>
      'Modificó una campaña de recomendación';

  @override
  String get spaceActionRecommendationPolicyChanged =>
      'Cambió la política de recomendaciones';

  @override
  String get spaceActionEncryptionRotated => 'Rotó la clave de cifrado';

  @override
  String get spaceActionCheckpointRecorded => 'Registró un punto de control';

  @override
  String spaceActionAuthorityWithdrawn(String member) {
    return 'Retiró retroactivamente la autoridad de $member';
  }

  @override
  String spaceActionAuthorityReturned(String member) {
    return 'Devolvió la autoridad a $member';
  }

  @override
  String get spaceActionOther => 'Realizó una acción administrativa';

  @override
  String spaceActionDetailChannel(String channel) {
    return 'Canal «$channel»';
  }

  @override
  String spaceActionDetailNewName(String name) {
    return 'Nombre nuevo: $name';
  }

  @override
  String spaceActionDetailRole(String role) {
    return 'Rol: $role';
  }

  @override
  String spaceActionDetailModeration(String action) {
    return 'Acción: $action';
  }

  @override
  String get spaceAccessDelegatedHint =>
      'Solo puedes gestionar roles por debajo de tu techo de permisos actual. Tus propios roles y los de otros gestores están bloqueados.';

  @override
  String get spaceAccessEmpty =>
      'Todavía no hay roles personalizados. Los roles integrados de la comunidad siguen aplicándose.';

  @override
  String get spaceAccessRoles => 'Roles personalizados';

  @override
  String get spaceAccessGroups => 'Grupos de participantes';

  @override
  String get spaceAccessRoleAdd => 'Añadir rol';

  @override
  String get spaceAccessRoleEdit => 'Editar rol';

  @override
  String get spaceAccessRoleDelete => 'Eliminar rol';

  @override
  String spaceAccessRoleDeleteConfirm(Object name) {
    return '¿Eliminar el rol «$name»? Sus asignaciones se retirarán en el mismo cambio firmado.';
  }

  @override
  String get spaceAccessRoleName => 'Nombre del rol';

  @override
  String spaceAccessRoleGrantSummary(num areas, num permissions) {
    String _temp0 = intl.Intl.pluralLogic(
      permissions,
      locale: localeName,
      other: '$permissions permisos',
      one: '1 permiso',
    );
    String _temp1 = intl.Intl.pluralLogic(
      areas,
      locale: localeName,
      other: '$areas áreas',
      one: '1 área',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String get spaceAccessPermissionAreas => 'Áreas de permisos';

  @override
  String get spaceAccessAddArea => 'Añadir otra área';

  @override
  String get spaceAccessAddDenyArea => 'Denegar un área';

  @override
  String get spaceAccessDenyScopeLabel => 'Área denegada';

  @override
  String get spaceAccessScopeLabel => 'Área';

  @override
  String get spaceAccessScopeTarget => 'Categoría o canal';

  @override
  String get spaceAccessScopeSpace => 'Toda la comunidad';

  @override
  String get spaceAccessScopeCategory => 'Categoría';

  @override
  String get spaceAccessScopeChannel => 'Canal';

  @override
  String get spaceAccessScopePosts => 'Publicaciones';

  @override
  String get spaceAccessScopeModeration => 'Moderación';

  @override
  String get spaceAccessScopeMembers => 'Miembros';

  @override
  String get spaceAccessScopeRoles => 'Roles';

  @override
  String get spaceAccessScopeSettings => 'Ajustes';

  @override
  String get spaceAccessScopeEncryption => 'Cifrado';

  @override
  String get spaceAccessScopeStorage => 'Almacenamiento';

  @override
  String get spaceAccessGroupAdd => 'Añadir grupo';

  @override
  String get spaceAccessGroupEdit => 'Editar grupo';

  @override
  String get spaceAccessGroupDelete => 'Eliminar grupo';

  @override
  String spaceAccessGroupDeleteConfirm(Object name) {
    return '¿Eliminar el grupo de participantes «$name»?';
  }

  @override
  String get spaceAccessGroupName => 'Nombre del grupo';

  @override
  String spaceAccessGroupSummary(num members, num roles) {
    String _temp0 = intl.Intl.pluralLogic(
      members,
      locale: localeName,
      other: '$members miembros',
      one: '1 miembro',
    );
    String _temp1 = intl.Intl.pluralLogic(
      roles,
      locale: localeName,
      other: '$roles roles',
      one: '1 rol',
    );
    return '$_temp0 · $_temp1';
  }

  @override
  String get spaceAccessDirectRoles => 'Asignar roles personalizados';

  @override
  String get spaceAccessNoRoles =>
      'Crea un rol personalizado antes de asignarlo.';

  @override
  String get spacePermissionView => 'Ver la comunidad';

  @override
  String get spacePermissionDistributeContent => 'Distribuir contenido';

  @override
  String get spacePermissionPublishMessages => 'Publicar mensajes';

  @override
  String get spacePermissionPublishPosts => 'Publicar entradas';

  @override
  String get spacePermissionManagePosts => 'Gestionar publicaciones';

  @override
  String get spacePermissionManageRecommendations =>
      'Gestionar recomendaciones';

  @override
  String get spacePermissionEnterVoice => 'Entrar en canales de voz';

  @override
  String get spacePermissionManageMembers => 'Gestionar miembros';

  @override
  String get spacePermissionManageRoles => 'Gestionar roles';

  @override
  String get spacePermissionModerate => 'Moderar';

  @override
  String get spacePermissionManageSettings => 'Gestionar ajustes';

  @override
  String get spacePermissionManageEncryption => 'Gestionar el cifrado';

  @override
  String get spacePermissionManageStorage =>
      'Gestionar almacenamiento y conservación';

  @override
  String get spacePermissionManageChannels => 'Gestionar canales';

  @override
  String get spaceMemberMuted =>
      'No puede publicar hasta que se le permita de nuevo';

  @override
  String get spaceMemberUnmute => 'Permitir publicar';

  @override
  String get spaceMemberPromote => 'Hacer administrador';

  @override
  String get spaceMemberDemote => 'Hacer miembro';

  @override
  String get spaceMemberRemove => 'Expulsar de la comunidad';

  @override
  String spaceMemberRemoveConfirm(String member) {
    return '¿Expulsar a $member y rotar las claves de acceso?';
  }

  @override
  String get spaceMemberBan => 'Vetar en la comunidad';

  @override
  String spaceMemberBanConfirm(String member) {
    return '¿Vetar de forma permanente a $member? Se revocará su pertenencia y se rotarán las claves de acceso protegidas. La acción firmada queda en el historial de moderación y se puede recurrir.';
  }

  @override
  String get spaceMemberTransferOwnership => 'Transferir la propiedad';

  @override
  String spaceMemberTransferOwnershipConfirm(String member) {
    return '¿Transferir la propiedad a $member? Pasarás a ser administrador, y solo la nueva propietaria podrá devolvértela.';
  }

  @override
  String get spaceAuthorityWithdraw => 'Retirar autoridad pasada';

  @override
  String get spaceAuthorityReturn => 'Devolver la autoridad';

  @override
  String spaceAuthorityWithdrawConfirm(String member) {
    return '¿A partir de qué momento deben dejar de contar las decisiones de $member? Los vetos y silencios que aplicó después se deshacen. El contenido eliminado y las rotaciones de claves no se pueden recuperar.';
  }

  @override
  String spaceAuthorityWithdrawSinceHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Las últimas $hours horas',
      one: 'La última hora',
    );
    return '$_temp0';
  }

  @override
  String spaceAuthorityWithdrawSinceDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Los últimos $days días',
      one: 'El último día',
    );
    return '$_temp0';
  }

  @override
  String get spaceAuthorityWithdrawSinceAlways =>
      'Todo lo que haya decidido alguna vez';

  @override
  String get spaceRenameTitle => 'Cambiar el nombre de la comunidad';

  @override
  String get spaceRenameAction => 'Cambiar el nombre';

  @override
  String get spaceRenameDenied =>
      'No tienes permiso para cambiar el nombre de esta comunidad';

  @override
  String get spaceLeave => 'Salir de la comunidad';

  @override
  String get spaceLeaveConfirm =>
      'Perderás el acceso a sus canales y publicaciones. Las claves protegidas se rotarán para el resto de miembros.';

  @override
  String get spaceOwnerLeaveHint =>
      'Transfiere la propiedad a otro miembro antes de salir de la comunidad.';

  @override
  String get spaceReplicationTitle => 'Redistribución de copias';

  @override
  String spaceReplicationNeighbors(int count) {
    return 'Distribuir a través de $count miembros cercanos';
  }

  @override
  String get spaceReplicationHint =>
      'Las copias las guardan los miembros con permiso para distribuir contenido. Cuantos más, mejor disponibilidad y recuperación, a costa de tráfico en este dispositivo.';

  @override
  String get spaceYou => 'Tú';

  @override
  String get feedEmpty => 'Tus novedades están vacías';

  @override
  String get feedEmptyHint =>
      'Las publicaciones de las comunidades activadas aparecerán aquí en orden cronológico.';

  @override
  String get feedPostHide => 'Ocultar de Novedades';

  @override
  String get feedPostHidden => 'Publicación oculta de tus Novedades';

  @override
  String get feedPostUndo => 'Deshacer';

  @override
  String get feedPostHideFailed =>
      'No se pudo actualizar esta preferencia de Novedades';

  @override
  String get feedFilterTitle => 'Filtrar publicaciones';

  @override
  String get feedFilterAll => 'Todas';

  @override
  String get feedFilterApply => 'Aplicar';

  @override
  String get feedFilterEmptyHint =>
      'Ninguna publicación coincide con los filtros elegidos.';

  @override
  String get feedFilterUpdateFailed =>
      'No se pudo actualizar el filtro de Novedades';

  @override
  String get feedFilterMentionsOnly =>
      'Solo las publicaciones que me mencionan';

  @override
  String get feedFilterMentionsOnlyHint =>
      'Se compara el node_id canónico aunque se muestre el nombre de un contacto o un usuario de la DHT.';

  @override
  String get feedFilterTypesTitle => 'Tipo de publicación';

  @override
  String get feedFilterTimeTitle => 'Momento de la publicación';

  @override
  String get feedFilterTimeAll => 'Cualquier momento';

  @override
  String get feedFilterTimeHour => 'La última hora';

  @override
  String get feedFilterTimeDay => 'El último día';

  @override
  String get feedFilterTimeWeek => 'La última semana';

  @override
  String get feedFilterTimeMonth => 'El último mes';

  @override
  String get feedFilterTimeCustom => 'Fecha y hora personalizadas';

  @override
  String get feedFilterCommunitiesTitle => 'Comunidades';

  @override
  String get feedFilterAllCommunities => 'Todas las comunidades';

  @override
  String get chatsEmpty => 'Todavía no hay conversaciones';

  @override
  String get chatsEmptyHint => 'Empieza un chat nuevo para escribir a alguien';

  @override
  String get chatNewMessageHint => 'Mensaje';

  @override
  String get chatSend => 'Enviar';

  @override
  String get notificationNewMessage => 'Mensaje nuevo';

  @override
  String get notificationMention => 'Te han mencionado';

  @override
  String get notificationReply => 'Responder';

  @override
  String get notificationReplyHint => 'Mensaje…';

  @override
  String get notificationsTitle => 'Notificaciones';

  @override
  String get notificationsEnabled => 'Mostrar notificaciones';

  @override
  String get notificationsPreview => 'Vista previa del mensaje';

  @override
  String get notificationsPreviewHidden =>
      'Oculta («mensaje nuevo», sin remitente ni texto)';

  @override
  String get notificationsPreviewFull => 'Completa (remitente y texto)';

  @override
  String get mentionsTitle => 'Menciones';

  @override
  String get mentionsOpenTooltip => 'Todas las menciones';

  @override
  String get mentionsEmpty => 'Todavía no hay menciones';

  @override
  String get mentionsEmptyHint =>
      'Aquí aparecerán los mensajes, las publicaciones y los comentarios que te mencionen.';

  @override
  String get mentionsLoadFailed => 'No se pudieron cargar las menciones';

  @override
  String get chatRequestSent => 'Solicitud enviada: esperando aprobación';

  @override
  String get chatRequestResend => 'Enviar de nuevo';

  @override
  String get chatRequestCancel => 'Cancelar';

  @override
  String get chatRequestCancelTitle => '¿Cancelar la solicitud?';

  @override
  String get chatRequestCancelBody =>
      'Quita esta solicitud y la conversación de tu dispositivo. Si ya le llegó, es posible que la haya visto.';

  @override
  String get chatBlockedContact => 'Has bloqueado a este contacto';

  @override
  String get chatRequestHint => 'Escribe una solicitud de contacto…';

  @override
  String get chatAttachTooltip => 'Adjuntar un archivo';

  @override
  String get chatVoiceMicDenied => 'Acceso al micrófono denegado';

  @override
  String get chatVoiceTooltip => 'Mensaje de voz';

  @override
  String get chatVnoteTooltip => 'Mensaje de vídeo';

  @override
  String get attachmentPreviewPhoto => 'Foto';

  @override
  String get attachmentPreviewVideo => 'Vídeo';

  @override
  String get attachmentPreviewSticker => 'Adhesivo';

  @override
  String get stickerTitle => 'Adhesivos';

  @override
  String get stickerImport => 'Importar desde las fotos';

  @override
  String get groupCreateTitle => 'Nuevo chat de grupo';

  @override
  String get groupCreateAction => 'Crear';

  @override
  String get groupOperationFailed =>
      'No se pudo actualizar el grupo. Comprueba la red e inténtalo de nuevo.';

  @override
  String get groupEncrypted => 'Cifrado de extremo a extremo';

  @override
  String get groupEncryptionPending => 'Mejora del cifrado pendiente';

  @override
  String get groupNameHint => 'Nombre del chat de grupo';

  @override
  String get groupNoMessages => 'Todavía no hay mensajes';

  @override
  String get groupMembersTooltip => 'Miembros';

  @override
  String get groupSyncSettingsTooltip => 'Sincronización del chat';

  @override
  String get groupConvertToCommunity => 'Convertir en comunidad';

  @override
  String get groupHideAfterReadTitle => 'Ocultar tras leer';

  @override
  String get groupHideAfterReadLocalTitle =>
      'Ocultar tras leer (este dispositivo)';

  @override
  String get groupHideAfterReadSubtitle =>
      'Pide al dispositivo de cada miembro que oculte un mensaje pasado este plazo desde que se mostró allí por primera vez. El registro conserva el mensaje: ocultar es cosa de la pantalla, y un dispositivo puede no atender la petición.';

  @override
  String get groupHideAfterReadLocalSubtitle =>
      'Solo este dispositivo. Si el grupo también pide un plazo, gana el más corto.';

  @override
  String get groupDisappearingTooltip => 'Mensajes temporales';

  @override
  String get groupDisappearingTitle => 'Mensajes temporales';

  @override
  String get groupDisappearingSubtitle =>
      'Los mensajes de este grupo se borran para TODOS al vencer el plazo. Solo el propietario puede cambiarlo, y los miembros con una versión antigua conservan sus copias.';

  @override
  String get groupDisappearingOff => 'No borrar';

  @override
  String get groupDisappearingCustom => 'Personalizado';

  @override
  String get groupDisappearingCustomTitle => 'Plazo personalizado';

  @override
  String get groupDisappearingMinutesSuffix => 'min';

  @override
  String get groupDisappearingFailed => 'No se pudo cambiar el plazo';

  @override
  String get groupConvertConfirm =>
      'Este chat pasa a ser una comunidad con canales, publicaciones y novedades. Se conservan los miembros y el historial. Se moverá a Comunidades. Esto no se puede deshacer.';

  @override
  String get groupConvertAction => 'Convertir';

  @override
  String get groupSyncNeighborsTitle => 'Sincronización del chat';

  @override
  String groupSyncNeighborsLabel(int count) {
    return 'Vecinos XOR: $count';
  }

  @override
  String get groupSyncNeighborsHint =>
      'A cuántos miembros más próximos por XOR se conecta este dispositivo para el historial del chat. Más vecinos mejoran la redundancia, pero gastan más tráfico. Este ajuste es local de este dispositivo.';

  @override
  String get groupRenameTitle => 'Cambiar el nombre del grupo';

  @override
  String get groupRenameAction => 'Cambiar el nombre';

  @override
  String get groupRenameDenied =>
      'No tienes permiso para cambiar el nombre de este grupo';

  @override
  String groupMembers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count miembros',
      one: '1 miembro',
    );
    return '$_temp0';
  }

  @override
  String get groupReply => 'Responder';

  @override
  String get groupAddMember => 'Añadir';

  @override
  String get groupMute => 'Silenciar';

  @override
  String get groupUnmute => 'Dejar de silenciar';

  @override
  String get groupPromote => 'Hacer administrador';

  @override
  String get groupDemote => 'Quitar administrador';

  @override
  String get groupRemove => 'Expulsar del grupo';

  @override
  String get groupLeave => 'Salir del grupo';

  @override
  String get groupLeaveConfirm =>
      'Dejarás de recibir los mensajes de este grupo.';

  @override
  String get groupNoContactsToAdd => 'No quedan contactos por añadir';

  @override
  String get groupImageOnly => 'Elige un archivo de imagen';

  @override
  String get groupImageTooLarge =>
      'La imagen es demasiado grande para enviarla incrustada';

  @override
  String get reactorsTitle => 'Reacciones';

  @override
  String get reactorsYou => 'Tú';

  @override
  String get settingsShowReactions => 'Mostrar reacciones';

  @override
  String get settingsShowReactionsHint =>
      'Las fichas de reacción bajo los mensajes y la barra de reacción rápida del menú del mensaje. Ocultarlas es solo local: las reacciones se siguen sincronizando.';

  @override
  String get stickerEmpty =>
      'Todavía no hay adhesivos: importa tus propias imágenes';

  @override
  String get stickerSharePack => 'Compartir el paquete';

  @override
  String get stickerPackTitle => 'Paquete de adhesivos';

  @override
  String get stickerPackDownload => 'Descargar';

  @override
  String get stickerPackInstall => 'Instalar';

  @override
  String stickerImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count adhesivos añadidos',
      one: '1 adhesivo añadido',
    );
    return '$_temp0';
  }

  @override
  String get stickerPackChooseTarget => '¿A qué paquete lo añadimos?';

  @override
  String get stickerPackNew => 'Paquete nuevo…';

  @override
  String get stickerPackNameHint => 'Nombre del paquete';

  @override
  String get stickerPackRename => 'Cambiar el nombre';

  @override
  String get stickerPackDelete => 'Eliminar el paquete';

  @override
  String stickerPackDeleteConfirm(String name) {
    return '¿Eliminar «$name» y sus adhesivos?';
  }

  @override
  String get stickerPackUnsigned => 'Paquete sin firmar';

  @override
  String stickerPackSignedBy(String author) {
    return 'Firmado por $author';
  }

  @override
  String get stickerPackBadSignature =>
      'Falló la comprobación de la firma: el paquete no se instaló';

  @override
  String get chatVnoteDenied => 'Acceso a la cámara o al micrófono denegado';

  @override
  String get chatVoiceRecordFailed => 'No se pudo grabar: inténtalo de nuevo';

  @override
  String get chatVoiceTranscribe => 'Transcribir';

  @override
  String get chatVoiceTranscribing => 'Transcribiendo…';

  @override
  String get chatVoiceTranscribeAs => 'Leer en otro idioma…';

  @override
  String get chatVoiceTranscribeLanguage => 'Idioma';

  @override
  String get chatVoiceTranscribeFailed => 'No se pudo transcribir';

  @override
  String get chatFileSave => 'Guardar';

  @override
  String get chatFileSaved => 'Archivo guardado';

  @override
  String get chatFileSaveFailed => 'No se pudo guardar el archivo';

  @override
  String get chatFileTooLarge => 'El archivo es demasiado grande';

  @override
  String get chatFileUnreadable => 'No se pudo leer el archivo';

  @override
  String get chatMsgEdit => 'Editar';

  @override
  String get chatMsgDeleteForEveryone => 'Eliminar para todos';

  @override
  String get chatMsgDeleteForMe => 'Eliminar para mí';

  @override
  String get chatMsgCopy => 'Copiar el texto';

  @override
  String get chatMsgCopied => 'Copiado';

  @override
  String get chatLoadEarlier => 'Cargar mensajes anteriores';

  @override
  String get settingsChatPageSize => 'Mensajes por página';

  @override
  String get settingsChatPageSizeHint =>
      'Cuántos mensajes recientes carga un chat; los más antiguos se cargan cuando hacen falta';

  @override
  String get settingsCloseToTray => 'Cerrar a la bandeja';

  @override
  String get settingsCloseToTrayHint =>
      'Al cerrar la ventana se oculta en la bandeja del sistema y sigue funcionando, así que los mensajes y las notificaciones siguen llegando. Desactivado: cerrar equivale a salir.';

  @override
  String get navStorage => 'Almacenamiento';

  @override
  String get navMenuTiles => 'Menú';

  @override
  String get cloudTitle => 'Nube personal';

  @override
  String get cloudUnavailable =>
      'La sincronización con la nube no está disponible hasta que el nodo esté listo';

  @override
  String get cloudEmpty => 'Tu nube está vacía';

  @override
  String get cloudEmptyHint =>
      'Los archivos y las notas se cifran localmente y solo se replican entre tus propios dispositivos vinculados.';

  @override
  String get cloudAdd => 'Añadir a la nube';

  @override
  String get cloudAddFile => 'Añadir archivo';

  @override
  String get cloudAddNote => 'Nota nueva';

  @override
  String get cloudImported => 'Archivo añadido a tu nube';

  @override
  String get cloudImportFailed => 'No se pudo importar el archivo';

  @override
  String get cloudLoadFailed => 'No se pudo cargar el índice de la nube';

  @override
  String get cloudReplication => 'Mantener en este dispositivo';

  @override
  String get cloudModeAll => 'Todo';

  @override
  String get cloudModeSelected => 'Lo seleccionado';

  @override
  String get cloudModeIndex => 'Solo el índice';

  @override
  String get cloudModeAllHint =>
      'Descargar automáticamente todos los elementos de la nube';

  @override
  String get cloudModeSelectedHint =>
      'Descargar automáticamente los elementos seleccionados';

  @override
  String get cloudModeIndexHint =>
      'Mostrar el índice y descargar solo cuando haga falta';

  @override
  String get cloudLocal => 'en este dispositivo';

  @override
  String get cloudRemote => 'en la nube';

  @override
  String get cloudChangedElsewhere => 'cambiado en otro dispositivo';

  @override
  String get cloudUsage => 'Almacenamiento usado';

  @override
  String get cloudUsageOnThisDevice => 'En este dispositivo';

  @override
  String get cloudUsageInCloud => 'Todo el índice';

  @override
  String get cloudUsageByDevice => 'Por dispositivo';

  @override
  String get cloudUsageThisDevice => 'este dispositivo';

  @override
  String cloudUsageItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos',
      one: '1 elemento',
      zero: 'ningún elemento',
    );
    return '$_temp0';
  }

  @override
  String cloudUsageNotHeldHere(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos no están aquí',
      one: '1 elemento no está aquí',
      zero: 'está todo aquí',
    );
    return '$_temp0';
  }

  @override
  String cloudReplicas(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count copias verificadas',
      one: '1 copia verificada',
      zero: 'sin copias verificadas',
    );
    return '$_temp0';
  }

  @override
  String get cloudDownload => 'Descargar a este dispositivo';

  @override
  String get cloudExport => 'Guardar en un archivo…';

  @override
  String get cloudExportDone => 'Archivo guardado';

  @override
  String get cloudExportFailed => 'No se pudo guardar el archivo';

  @override
  String get cloudShare => 'Compartir con un contacto';

  @override
  String get cloudShareTitle => 'Compartir con';

  @override
  String get cloudNoContacts =>
      'No hay contactos aceptados con quien compartir';

  @override
  String get cloudShared => 'Archivo compartido';

  @override
  String get cloudShareFailed => 'No se pudo compartir el archivo';

  @override
  String get cloudPublicLink => 'Enlace privado';

  @override
  String get cloudPublicCopy => 'Copiar enlace';

  @override
  String get cloudPublicCopied => 'Enlace privado copiado';

  @override
  String get cloudPublicRevoke => 'Revocar enlace';

  @override
  String get cloudPublicRevoked =>
      'Enlace revocado; las descargas ya hechas no se pueden borrar';

  @override
  String get cloudPublicFailed => 'No se pudo crear el enlace privado';

  @override
  String get cloudPublicImport => 'Abrir un enlace privado';

  @override
  String get cloudPublicPasteHint => 'Pega un enlace xveil://cloud';

  @override
  String get cloudPublicOpenFailed =>
      'No se pudo abrir ni verificar el enlace privado';

  @override
  String get cloudSelect => 'Mantener seleccionado';

  @override
  String get cloudUnselect => 'Dejar de mantenerlo';

  @override
  String get cloudVerify => 'Verificar y reparar';

  @override
  String get cloudVerifyOk =>
      'Los archivos locales de la nube pasaron la verificación';

  @override
  String cloudRepairStarted(int count) {
    return 'Reparación solicitada para $count archivos dañados';
  }

  @override
  String get cloudDelete => 'Eliminar';

  @override
  String get cloudDeleteTitle => '¿Eliminar de tu nube?';

  @override
  String get cloudDeleteBody =>
      'El elemento desaparecerá de todos los dispositivos vinculados. Este dispositivo lo conserva en la papelera hasta que la vacíes.';

  @override
  String get cloudTrash => 'Papelera';

  @override
  String get cloudTrashEmptyState => 'La papelera está vacía';

  @override
  String get cloudTrashHint =>
      'Los elementos eliminados siguen en este dispositivo hasta que se vacía la papelera. Los demás dispositivos ya los ven como eliminados.';

  @override
  String get cloudTrashRestore => 'Restaurar';

  @override
  String get cloudTrashDeleteForever => 'Eliminar para siempre';

  @override
  String get cloudTrashEmptyAction => 'Vaciar la papelera';

  @override
  String cloudTrashRestored(String name) {
    return '«$name» restaurado';
  }

  @override
  String get cloudTrashEmptied => 'Papelera vaciada';

  @override
  String get cloudSharedEmpty =>
      'Todavía no hay archivos en esta carpeta compartida';

  @override
  String get cloudSharedAddFile => 'Añadir un archivo de tu nube';

  @override
  String get cloudSharedAddEmpty =>
      'No hay archivos locales de la nube que compartir';

  @override
  String get cloudSharedFetch => 'Descargar';

  @override
  String get cloudSharedFetchFailed => 'No se pudo descargar el archivo';

  @override
  String get cloudPublicDirPublish => 'Publicar con mi apodo';

  @override
  String get cloudPublicDirWarning =>
      'Cualquiera que conozca tu apodo verá esta carpeta y sabrá que es tuya. Esto es público y queda ligado a tu identidad, a diferencia de un enlace de un solo uso. Los archivos nuevos que añadas a la carpeta también quedarán a la vista.';

  @override
  String get cloudPublicDirConfirm => 'Publicar públicamente';

  @override
  String get cloudPublicDirPublished => 'Carpeta publicada con tu apodo';

  @override
  String get cloudPublicDirFailed => 'No se pudo publicar el directorio';

  @override
  String get cloudPublicDirOpen => 'Abrir un directorio público';

  @override
  String get cloudPublicDirNicknameHint => 'apodo';

  @override
  String get cloudPublicDirResolve => 'Abrir';

  @override
  String get cloudPublicDirNotFound =>
      'No hay ningún directorio público con ese apodo';

  @override
  String get cloudPublicDirUnpublish => 'Dejar de publicar';

  @override
  String get cloudPublicDirUnpublished => 'Directorio despublicado';

  @override
  String get cloudNewFolder => 'Carpeta nueva';

  @override
  String get cloudFolderNameHint => 'Nombre de la carpeta';

  @override
  String get cloudFolderCreate => 'Crear';

  @override
  String get cloudFolderRename => 'Cambiar el nombre de la carpeta';

  @override
  String get cloudFolderDelete => 'Eliminar la carpeta';

  @override
  String cloudFolderDeleteTitle(String name) {
    return '¿Eliminar la carpeta «$name»?';
  }

  @override
  String get cloudFolderDeleteBody =>
      'Todo lo que hay dentro sube a la carpeta más cercana que quede. No se elimina nada de tu nube.';

  @override
  String get cloudMoveFolder => 'Mover la carpeta';

  @override
  String get cloudStorageRoot => 'Almacenamiento';

  @override
  String get cloudFolderShare => 'Compartir el enlace de la carpeta';

  @override
  String get cloudFolderShareCreated => 'Enlace de la carpeta copiado';

  @override
  String get cloudFolderShareEmpty =>
      'Esta carpeta todavía no tiene archivos descargados que compartir';

  @override
  String get cloudFolderShareFailed =>
      'No se pudo crear el enlace de la carpeta';

  @override
  String get cloudFolderShareExisting => 'Enlace de la carpeta';

  @override
  String get cloudFolderShareRevoke => 'Revocar el enlace';

  @override
  String get cloudFolderShareRevoked => 'Enlace de la carpeta revocado';

  @override
  String get cloudFolderShareRefresh => 'Actualizar el contenido compartido';

  @override
  String get cloudFolderShareRefreshed => 'Carpeta compartida actualizada';

  @override
  String get cloudFolderOpen => 'Abrir un enlace de carpeta';

  @override
  String get cloudFolderOpenHint => 'Pega un enlace de carpeta xveil://cloud';

  @override
  String get cloudFolderOpenTitle => 'Carpeta compartida';

  @override
  String get cloudFolderOpenFailed =>
      'No se pudo abrir el enlace de la carpeta';

  @override
  String get cloudFolderFileDownload => 'Descargar';

  @override
  String get cloudFolderFileDownloaded => 'Guardado en tu nube';

  @override
  String get cloudFolderFileFailed => 'No se pudo descargar el archivo';

  @override
  String get cloudFolderEmpty => 'Esta carpeta está vacía';

  @override
  String cloudFolderItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos',
      one: '1 elemento',
      zero: 'vacía',
    );
    return '$_temp0';
  }

  @override
  String get cloudMoveToFolder => 'Mover a una carpeta';

  @override
  String get cloudMoveToRoot => 'Raíz del almacenamiento';

  @override
  String get cloudFolderMoved => 'Documento movido';

  @override
  String get cloudFolderFailed => 'No se pudo actualizar la carpeta';

  @override
  String get cloudRename => 'Cambiar el nombre';

  @override
  String get cloudRenameHint => 'Nombre del archivo';

  @override
  String get cloudRenameFailed => 'No se pudo cambiar el nombre del archivo';

  @override
  String get cloudSearch => 'Buscar';

  @override
  String get cloudSearchHint => 'Buscar en el almacenamiento';

  @override
  String get cloudSearchEmpty => 'No se encontró nada';

  @override
  String get cloudSettings => 'Ajustes de la nube';

  @override
  String get cloudSort => 'Ordenar';

  @override
  String get cloudSortByName => 'Por nombre';

  @override
  String get cloudSortByDate => 'Por fecha';

  @override
  String get cloudSortBySize => 'Por tamaño';

  @override
  String cloudSelectedCount(int count) {
    return '$count seleccionados';
  }

  @override
  String cloudBulkDeleteTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementos',
      one: '1 elemento',
    );
    return '¿Eliminar $_temp0 de tu nube?';
  }

  @override
  String get cloudFolderEmptyHint =>
      'Las notas y los archivos que crees aquí se quedarán en esta carpeta.';

  @override
  String get cloudSingleCopy => 'copia única';

  @override
  String get cloudNoteNew => 'Nota nueva';

  @override
  String get cloudNoteEdit => 'Editar la nota';

  @override
  String get cloudNoteTitleHint => 'Título';

  @override
  String get cloudNotePreview => 'Vista previa';

  @override
  String get cloudNoteEditAction => 'Editar';

  @override
  String get cloudNoteBodyHint => 'Escribe una nota privada…';

  @override
  String get cloudNoteSave => 'Guardar';

  @override
  String get cloudNoteLoadFailed => 'No se pudo cargar ni verificar la nota';

  @override
  String get cloudNoteSaveFailed => 'No se pudo guardar la nota';

  @override
  String get cloudNoteTitleRequired => 'Escribe un título';

  @override
  String get cloudNoteTooLarge => 'La nota es demasiado grande (máximo 1 MiB)';

  @override
  String get cloudNoteConflictTitle => 'Esta nota cambió en otro dispositivo';

  @override
  String get cloudNoteConflictBody =>
      'Revisa la versión actual de la nube y combínala con tu borrador antes de guardar.';

  @override
  String get cloudNoteRemoteVersion => 'Versión actual de la nube';

  @override
  String get cloudNoteYourDraft => 'Tu borrador combinado';

  @override
  String get cloudNoteUseRemote => 'Usar la versión de la nube';

  @override
  String get cloudNoteSaveMerged => 'Guardar la versión combinada';

  @override
  String cloudNoteBranches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count versiones sin conexión conservadas',
      one: '1 versión conservada',
    );
    return '$_temp0';
  }

  @override
  String get cloudNoteReviewBranches => 'Revisar las versiones';

  @override
  String cloudNoteVersion(int number) {
    return 'Versión conservada $number';
  }

  @override
  String get cloudNoteBranchesUnavailable =>
      'Descarga todas las versiones conservadas antes de combinar';

  @override
  String get cloudNoteMergeReady =>
      'Combinación preparada: guarda la nota para resolver todas las versiones';

  @override
  String get cloudAttachment => 'Adjunto';

  @override
  String get cloudAttachmentMissing => 'Adjunto no disponible';

  @override
  String get cloudAttachmentGone => 'Este adjunto ya no está en tu nube';

  @override
  String get cloudAttachmentInsert => 'Adjuntar un archivo';

  @override
  String get cloudAttachmentPick => 'Adjuntar desde tu nube';

  @override
  String get cloudAttachmentUpload => 'Subir un archivo nuevo…';

  @override
  String get cloudAttachmentEmpty =>
      'Todavía no hay nada en tu nube que adjuntar';

  @override
  String get cloudAttachmentFetched => 'Adjunto descargado en este dispositivo';

  @override
  String get cloudAttachmentFetchFailed => 'No se pudo descargar el adjunto';

  @override
  String get settingsCatAccount => 'Identidades y cuenta';

  @override
  String get settingsCatAccountHint => 'Cambiar, añadir, gestionar, anonimato';

  @override
  String get settingsCatPrivacy => 'Privacidad';

  @override
  String get settingsCatPrivacyHint => 'Política P2P, solicitudes de firma';

  @override
  String get settingsCatChats => 'Chats y notificaciones';

  @override
  String get settingsCatChatsHint =>
      'Notificaciones, entrega en segundo plano, tamaño de página';

  @override
  String get settingsCatData => 'Datos y almacenamiento';

  @override
  String get settingsCatDataHint =>
      'Tamaño del contenedor, compactación, archivos';

  @override
  String get settingsCatAppearanceHint => 'Idioma, panel de carpetas';

  @override
  String get searchHint => 'Buscar';

  @override
  String get searchMessagesSection => 'Mensajes';

  @override
  String get searchNoResults => 'Sin resultados';

  @override
  String get chatMsgPin => 'Fijar';

  @override
  String get chatMsgUnpin => 'Dejar de fijar';

  @override
  String get chatPinnedLabel => 'Mensaje fijado';

  @override
  String get savedMessages => 'Mensajes guardados';

  @override
  String get savedNoteHint => 'Nota para mí…';

  @override
  String get chatFormatTooltip => 'Formato';

  @override
  String get chatFormatBold => 'Negrita';

  @override
  String get chatFormatItalic => 'Cursiva';

  @override
  String get chatFormatUnderline => 'Subrayado';

  @override
  String get chatFormatStrike => 'Tachado';

  @override
  String get chatFormatCode => 'Código';

  @override
  String get chatFormatSpoiler => 'Spoiler';

  @override
  String get chatFormatQuote => 'Cita';

  @override
  String get chatLinkCopied => 'Enlace copiado';

  @override
  String get chatCodeCopied => 'Código copiado';

  @override
  String get linkDialogTitle => '¿Abrir el enlace?';

  @override
  String get linkOpen => 'Abrir';

  @override
  String get linkCopy => 'Copiar';

  @override
  String get linkOpenFailed => 'No se pudo abrir el enlace';

  @override
  String get p2pSelectedTitle => 'Contactos seleccionados';

  @override
  String get p2pSelectedHint =>
      'Contactos con conexión P2P directa permitida bajo la política «Solo los seleccionados». Actívalo para concedérsela; desactivado, se sigue la política general.';

  @override
  String get p2pSelectedEmpty => 'Todavía no hay contactos aceptados';

  @override
  String get trayShow => 'Mostrar';

  @override
  String get trayHide => 'Ocultar';

  @override
  String get trayIdentities => 'Identidades';

  @override
  String get trayLock => 'Bloquear';

  @override
  String get trayQuit => 'Salir';

  @override
  String trayUnread(String count) {
    return '$count sin leer';
  }

  @override
  String get chatDeleteChatTitle => '¿Eliminar este chat?';

  @override
  String get chatDeleteChatBody =>
      'La conversación y todos sus mensajes se borran de este dispositivo. A la otra persona no se le avisa.';

  @override
  String get chatDeleteNotifyPeer => 'Avisar a la otra persona';

  @override
  String get chatDeletedByPeer =>
      'La otra persona eliminó este chat en su dispositivo';

  @override
  String get chatDisappearingTitle => 'Mensajes temporales';

  @override
  String get chatDisappearingSubtitle =>
      'Los mensajes de este chat se borran en AMBOS dispositivos al vencer el plazo. Cualquiera de los dos puede cambiarlo.';

  @override
  String get chatDisappearingOff => 'Desactivado';

  @override
  String get chatHideAfterReadTitle => 'Ocultar tras leer';

  @override
  String get chatHideAfterReadSubtitle =>
      'Se cuenta desde que CADA dispositivo mostró el mensaje por primera vez, así que los momentos difieren. El mensaje se oculta, no se borra, y un dispositivo puede no respetarlo: aquí no hay confirmaciones de lectura ni forma de imponerlo.';

  @override
  String chatDisappearingSetNotice(String window) {
    return 'Mensajes temporales: $window';
  }

  @override
  String chatHideAfterReadNotice(String window) {
    return 'Ocultar tras leer: $window';
  }

  @override
  String chatDisappearingAndHideNotice(String window, String readWindow) {
    return 'Mensajes temporales: $window · ocultar tras leer: $readWindow';
  }

  @override
  String get chatDisappearingOffNotice => 'Mensajes temporales desactivados';

  @override
  String chatDisappearingSeconds(int n) {
    return '$n s';
  }

  @override
  String chatDisappearingMinutes(int n) {
    return '$n min';
  }

  @override
  String chatDisappearingHours(int n) {
    return '$n h';
  }

  @override
  String chatDisappearingDays(int n) {
    return '$n d';
  }

  @override
  String get chatEditTitle => 'Editar el mensaje';

  @override
  String get chatEditSave => 'Guardar';

  @override
  String get chatDeleteTitle => '¿Eliminar el mensaje?';

  @override
  String get chatDeleteForMeBody =>
      'Se borra de forma permanente de este dispositivo.';

  @override
  String get chatDeleteForEveryoneBody =>
      'Se borra aquí y se envía una petición de borrado a la otra persona, pero es posible que ya lo haya visto o copiado.';

  @override
  String get chatDeleteConfirm => 'Eliminar';

  @override
  String get chatEdited => 'editado';

  @override
  String get chatMenuRetention => 'Borrado automático';

  @override
  String get retentionUnlimited => 'Nunca';

  @override
  String get retention7 => 'Al cabo de 1 semana';

  @override
  String get retention30 => 'Al cabo de 1 mes';

  @override
  String get retention90 => 'Al cabo de 3 meses';

  @override
  String get retention365 => 'Al cabo de 1 año';

  @override
  String get retentionCustom => 'Personalizado…';

  @override
  String retentionCustomN(int days) {
    return 'Personalizado ($days días)';
  }

  @override
  String get retentionCustomTitle => 'Eliminar al cabo de (días)';

  @override
  String get retentionDaysSuffix => 'días';

  @override
  String get retentionApplied => 'Los mensajes más antiguos se eliminarán';

  @override
  String get chatMenuRename => 'Cambiar el nombre';

  @override
  String get chatRenameTitle => 'Nombre local';

  @override
  String get chatMenuPin => 'Fijar arriba';

  @override
  String get chatMenuUnpin => 'Dejar de fijar';

  @override
  String get chatMenuMute => 'Silenciar las notificaciones';

  @override
  String get chatMenuUnmute => 'Dejar de silenciar las notificaciones';

  @override
  String get notificationMuteModeTitle => '¿Qué debe seguir avisándote?';

  @override
  String get notificationMuteMentionsOnly => 'Solo las menciones';

  @override
  String get notificationMuteMentionsOnlyHint =>
      'Silencia los avisos de mensajes nuevos, pero avisa cuando te mencionen';

  @override
  String get notificationMuteNone => 'Nada';

  @override
  String get notificationMuteNoneHint =>
      'Silencia todos los avisos, también las menciones';

  @override
  String notificationMuteCurrentMentionsOnly(String until) {
    return 'Solo las menciones hasta el $until';
  }

  @override
  String notificationMuteCurrentNone(String until) {
    return 'Silenciado hasta el $until';
  }

  @override
  String get chatMenuMarkRead => 'Marcar como leído';

  @override
  String get chatMenuArchive => 'Archivar';

  @override
  String get chatMenuUnarchive => 'Desarchivar';

  @override
  String get chatsArchiveSection => 'Archivo';

  @override
  String get chatMenuFolders => 'Carpetas';

  @override
  String get chatsFolderAll => 'Todos';

  @override
  String get chatsFolderNew => 'Carpeta nueva';

  @override
  String get chatsFolderName => 'Nombre de la carpeta';

  @override
  String get chatsFolderRename => 'Cambiar el nombre de la carpeta';

  @override
  String get chatsFolderDelete => 'Eliminar la carpeta';

  @override
  String get chatsFolderUnnamed => 'Sin título';

  @override
  String get chatsFolderEmpty => 'No hay chats en esta carpeta';

  @override
  String get chatsFolderNoneYet => 'Todavía no hay carpetas';

  @override
  String get chatMsgRequestSignature => 'Pedir la firma';

  @override
  String get chatSignatureRequested => 'Firma solicitada';

  @override
  String get chatSignaturePending => 'Esperando la firma del autor';

  @override
  String get chatSignatureVerified => 'Autoría verificada';

  @override
  String get chatSignatureRefused => 'El autor se negó a firmar';

  @override
  String get chatSignatureFailed => 'La firma no se pudo verificar';

  @override
  String signatureAskTitle(String who) {
    return '$who te pide que confirmes que escribiste el mensaje de abajo';
  }

  @override
  String get signatureAskConfirm => 'Firmar';

  @override
  String get settingsSignaturePolicy => 'Solicitudes de firma';

  @override
  String get settingsSignaturePolicyHint =>
      'Qué responder cuando un contacto te pide demostrar que escribiste un mensaje';

  @override
  String get screenLockTitle => 'Bloqueado';

  @override
  String screenLockWait(int seconds) {
    return 'Demasiados intentos. Inténtalo de nuevo en $seconds s';
  }

  @override
  String get settingsScreenLock => 'Bloquear la pantalla en segundo plano';

  @override
  String get settingsScreenLockHint =>
      'Vuelve a pedir la contraseña después de que la aplicación haya estado fuera de foco. Los mensajes siguen llegando y las notificaciones siguen funcionando: solo se tapa la pantalla.';

  @override
  String get screenLockOff => 'Desactivado';

  @override
  String get screenLockImmediately => 'De inmediato';

  @override
  String get screenLockOneMinute => 'Al cabo de 1 minuto';

  @override
  String get screenLockFiveMinutes => 'Al cabo de 5 minutos';

  @override
  String get screenLockFifteenMinutes => 'Al cabo de 15 minutos';

  @override
  String get settingsApiTitle => 'API de automatización';

  @override
  String get settingsApiHint =>
      'Desactivada. API REST local para bots y scripts (solo localhost)';

  @override
  String get settingsApiReadOnly => 'Solo lectura';

  @override
  String get settingsApiReadOnlyHint =>
      'Solo lecturas y eventos: las escrituras (enviar, llamar) se rechazan';

  @override
  String get settingsApiAddToken => 'Añadir token';

  @override
  String get settingsApiTokenName => 'Nombre del token (por ejemplo, bot)';

  @override
  String get settingsApiFileFolders => 'Carpetas permitidas';

  @override
  String get settingsApiFileFoldersHint =>
      'Este token solo puede enviar archivos desde estas carpetas. Sin ninguna, el envío de archivos locales se rechaza.';

  @override
  String get settingsApiFileFoldersNone =>
      'Sin carpetas: el envío de archivos locales está desactivado';

  @override
  String get settingsApiAddFolder => 'Añadir una carpeta';

  @override
  String get settingsApiRevoke => 'Revocar';

  @override
  String get settingsApiCopyToken => 'Copiar el token';

  @override
  String get settingsCommunication => 'Comunicación';

  @override
  String get settingsP2PPolicy => 'Política P2P';

  @override
  String get settingsP2PPolicyHint =>
      'Permite el transporte directo para llamadas, contenido pesado, archivos e intercambio entre dispositivos cuando ambas partes lo consienten.';

  @override
  String get settingsP2PPolicyAnonymousHint =>
      'El P2P está desactivado mientras esta identidad usa enrutado anónimo.';

  @override
  String get p2pPolicyAllowAll => 'Permitir a todo el mundo';

  @override
  String get p2pPolicyContacts => 'Permitir a los contactos';

  @override
  String get p2pPolicySelected => 'Solo a los contactos seleccionados';

  @override
  String get p2pPolicyDenied => 'Denegar';

  @override
  String get signaturePolicyAsk => 'Preguntar cada vez';

  @override
  String get signaturePolicyAuto => 'Firmar automáticamente';

  @override
  String get signaturePolicyRefuse => 'Negarse siempre';

  @override
  String get settingsKeepNodeBackground =>
      'Seguir funcionando en segundo plano';

  @override
  String get settingsKeepNodeBackgroundHint =>
      'Sigue recibiendo mensajes con la aplicación minimizada o la pantalla apagada. Muestra una notificación permanente y gasta más batería.';

  @override
  String get settingsFolderPanel => 'Panel de carpetas';

  @override
  String get settingsFolderPanelHint =>
      'Dónde se muestran las carpetas de chats';

  @override
  String get folderPanelLeft => 'Cajón izquierdo';

  @override
  String get folderPanelRight => 'Cajón derecho';

  @override
  String get folderPanelTop => 'Barra superior';

  @override
  String get mute30m => '30 minutos';

  @override
  String get mute1h => '1 hora';

  @override
  String get mute8h => '8 horas';

  @override
  String get mute3d => '3 días';

  @override
  String get mute1w => '1 semana';

  @override
  String get mute1mo => '1 mes';

  @override
  String get muteForever => 'Hasta que vuelva a activarlo';

  @override
  String get muteCustom => 'Personalizado…';

  @override
  String get muteCustomTitle => '¿Cuánto tiempo lo silenciamos?';

  @override
  String get muteHoursSuffix => 'horas';

  @override
  String get chatMenuCommunicationSettings => 'Ajustes de comunicación';

  @override
  String get chatMenuP2P => 'Conexión P2P';

  @override
  String get contactP2PFollowGlobal => 'Seguir la política general';

  @override
  String get contactP2PAllow => 'Permitir';

  @override
  String get contactP2PDeny => 'Denegar';

  @override
  String get contactP2PHint =>
      'Permitir hace que los mensajes y las llamadas con este contacto tomen una ruta directa: mucho más rápido, y le muestra tu dirección IP. Cualquier otra opción mantiene la conversación por la ruta de relés. Los mensajes se entregan igualmente.';

  @override
  String get chatMenuAllowPeerDelete =>
      'Dejar que este contacto borre en mi dispositivo';

  @override
  String get chatMenuAllowPeerDeleteHint =>
      'Si está activado, cuando retire un mensaje o limpie el historial también se borrará tu copia. Desactivado, conservas tus copias aunque borre para todos.';

  @override
  String get chatMenuUnblock => 'Desbloquear';

  @override
  String get chatMenuClearHistory => 'Limpiar el historial';

  @override
  String get chatMenuDeleteConversation => 'Eliminar la conversación';

  @override
  String get chatClearHistoryTitle => '¿Limpiar el historial?';

  @override
  String get chatClearHistoryBody =>
      'Todos los mensajes de este chat se borran de este dispositivo. El contacto se mantiene, así que puedes seguir escribiéndole. A la otra persona no se le avisa.';

  @override
  String get chatClearHistoryConfirm => 'Limpiar';

  @override
  String get chatMsgInfo => 'Información del mensaje';

  @override
  String get chatMsgHistory => 'Historial de ediciones';

  @override
  String get chatHistoryEmpty => 'No hay versiones anteriores';

  @override
  String get chatHistoryOriginal => 'Original';

  @override
  String get chatHistoryEdited => 'Editado';

  @override
  String get msgInfoId => 'ID';

  @override
  String get msgInfoTime => 'Hora';

  @override
  String get msgInfoDirection => 'Dirección';

  @override
  String get msgInfoStatus => 'Estado';

  @override
  String get msgInfoFile => 'Archivo';

  @override
  String get msgInfoSize => 'Tamaño';

  @override
  String get msgInfoAuthor => 'Autor';

  @override
  String get msgInfoSeq => 'Secuencia';

  @override
  String get msgInfoEdited => 'Editado';

  @override
  String get msgInfoYes => 'Sí';

  @override
  String get chatMsgCopyMeta => 'Copiar con los metadatos';

  @override
  String get chatMsgReply => 'Responder';

  @override
  String get chatMsgForward => 'Reenviar';

  @override
  String get chatMsgSelect => 'Seleccionar';

  @override
  String get chatMsgDelete => 'Eliminar';

  @override
  String get chatMsgDeleteTitle => '¿Eliminar los mensajes?';

  @override
  String get chatReplyingTo => 'Respondiendo a';

  @override
  String get chatQuoteUnavailable => 'Mensaje citado';

  @override
  String get chatFileLabel => 'Archivo';

  @override
  String get chatForwarded => 'Reenviado';

  @override
  String get chatYou => 'tú';

  @override
  String chatForwardedFrom(String name) {
    return 'Reenviado de $name';
  }

  @override
  String get chatForwardTo => 'Reenviar a';

  @override
  String get chatForwardNoTargets =>
      'No hay contactos aceptados a quien reenviarlo';

  @override
  String chatMsgDeleteSelectedBody(int count) {
    return '¿Eliminar $count mensaje(s) seleccionado(s)?';
  }

  @override
  String get dirIncoming => 'Recibido';

  @override
  String get dirOutgoing => 'Enviado';

  @override
  String get msgStatusSending => 'Enviando…';

  @override
  String get msgStatusSent => 'Enviado';

  @override
  String get msgStatusDelivered => 'Entregado';

  @override
  String get msgStatusFailed => 'Falló';

  @override
  String get identityPickerTitle => 'Elige una identidad';

  @override
  String get identityPickerSubtitle =>
      'Esta caja fuerte contiene varias identidades: elige con cuál actuar.';

  @override
  String get networkTitle => 'Red superpuesta';

  @override
  String get networkStatusConnected => 'Conectado';

  @override
  String get networkStatusConnecting => 'Conectando…';

  @override
  String get networkStatusOffline => 'Sin conexión';

  @override
  String networkPeers(int count) {
    return '$count pares';
  }

  @override
  String get settingsTitle => 'Ajustes';

  @override
  String get settingsStorage => 'Almacenamiento y espacios';

  @override
  String get settingsStorageCompact => 'Compactar el almacenamiento';

  @override
  String get settingsStorageCompactBody =>
      'Recupera espacio sin usar; la aplicación se reabre. Conserva SOLO el espacio desbloqueado: cualquier otra identidad oculta de este contenedor se descarta.';

  @override
  String settingsStorageReclaimable(String size) {
    return 'Se pueden recuperar $size compactándolo';
  }

  @override
  String settingsStorageBloatTitle(String size) {
    return 'Compactar liberaría unos $size';
  }

  @override
  String get settingsStorageBloatBody =>
      'La mayor parte de este archivo es relleno que dejaron escrituras anteriores: es normal en este almacenamiento, pero nunca se encoge solo. Compáctalo cuando te venga bien.';

  @override
  String get settingsStorageCompactDone => 'Recuperado';

  @override
  String get settingsStorageCompactFailed =>
      'No se pudo compactar el almacenamiento';

  @override
  String get settingsStorageAutoCompact =>
      'Compactar automáticamente al desbloquear';

  @override
  String get settingsStorageAutoCompactBody =>
      'Compacta automáticamente cuando el contenedor se infla. Actívalo SOLO si en este contenedor no vive ninguna otra identidad oculta: la compactación conserva únicamente el espacio desbloqueado.';

  @override
  String get settingsCompactOffer => 'Ofrecer compactar';

  @override
  String get settingsCompactOfferHint =>
      'Avisa cuando gran parte del contenedor es relleno muerto y ofrece recuperarlo. La oferta pide antes la contraseña de cada identidad, así que no se pierde nada oculto.';

  @override
  String get settingsCompactOfferPeriod => 'Preguntar no más a menudo que';

  @override
  String get settingsCompactOfferThreshold => 'Solo si se recuperaría al menos';

  @override
  String get compactOfferTitle => '¿Recuperar espacio de almacenamiento?';

  @override
  String compactOfferBody(String now, String after) {
    return 'Este contenedor ocupa $now, y unos $after son datos vivos. Compactar lo reescribe sin el relleno muerto.';
  }

  @override
  String get compactOfferApprox =>
      'Al menos esto: las otras identidades del contenedor cuentan como muertas hasta que las abras abajo.';

  @override
  String get compactOfferPasswordsHint =>
      'Introduce la contraseña de CADA identidad de este contenedor. Lo que no se abra aquí, la compactación lo elimina.';

  @override
  String get compactOfferPassword => 'Contraseña de la identidad';

  @override
  String get compactOfferAdd => 'Abrir y conservar';

  @override
  String get compactOfferUnknown => 'Esa contraseña no abre nada aquí';

  @override
  String get compactOfferAlready => 'Ya está en la lista';

  @override
  String get compactOfferKeeping => 'Se conservarán';

  @override
  String compactOfferWithMaster(int count) {
    return 'y $count más bajo ella';
  }

  @override
  String get compactOfferRun => 'Compactar ahora';

  @override
  String settingsCompactOfferDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count días',
      one: '1 día',
    );
    return '$_temp0';
  }

  @override
  String get settingsStorageLeanPadding => 'Ahorrar espacio de almacenamiento';

  @override
  String get settingsStorageLeanPaddingBody =>
      'Activado de forma predeterminada: las escrituras futuras usan menos relleno, así que el contenedor crece mucho menos. Desactívalo para enmascarar mejor los cambios de tamaño. Se aplica cuando la aplicación se reabre.';

  @override
  String get settingsStoragePasswordHint => 'Tu contraseña';

  @override
  String get settingsAppearance => 'Apariencia';

  @override
  String get settingsAbout => 'Acerca de';

  @override
  String get settingsLanguage => 'Idioma';

  @override
  String get settingsLockNow => 'Bloquear ahora';

  @override
  String get settingsSwitchIdentity => 'Cambiar de identidad';

  @override
  String get settingsAddIdentity => 'Añadir una identidad';

  @override
  String get settingsFiles => 'Archivos';

  @override
  String get settingsFilesHint =>
      'Límite de descarga automática y tipos bloqueados';

  @override
  String get fileSettingsTitle => 'Descargas de archivos';

  @override
  String get fileAutoLimit => 'Descargar automáticamente hasta';

  @override
  String get fileAutoLimitHint =>
      'Los archivos más grandes se ofrecen: tú decides si descargarlos.';

  @override
  String get fileAlwaysAsk => 'Preguntar siempre';

  @override
  String get fileBlockedTitle => 'Nunca descargar automáticamente estos tipos';

  @override
  String get fileBlockedHint =>
      'Estos siempre esperan a que los toques (por ejemplo, apk o exe), aunque sean pequeños.';

  @override
  String get fileAddType => 'Añadir un tipo';

  @override
  String get fileTypeHint => 'Extensión, por ejemplo apk';

  @override
  String get fileDownloadTitle => 'Descargar el archivo';

  @override
  String get fileSaveEncrypted => 'Almacenamiento cifrado';

  @override
  String get fileSaveEncryptedHint =>
      'Se guarda en la aplicación, cifrado en el disco';

  @override
  String get fileSavePlain => 'Guardar en el disco (sin cifrar)';

  @override
  String get fileSavePlainHint =>
      'Un archivo normal que tú eliges: no está protegido';

  @override
  String get fileSavePlainWarn =>
      'Este archivo se guardará SIN CIFRAR en el disco. Cualquiera con acceso al dispositivo podrá leerlo. ¿Continuar?';

  @override
  String get fileSavePlainConfirm => 'Guardar sin cifrar';

  @override
  String get fileLargeMode => 'Archivos grandes';

  @override
  String get fileLargeModeHint =>
      'Cuando descargas un archivo demasiado grande para el volumen oculto';

  @override
  String get fileLargeModeAsk => 'Preguntar cada vez';

  @override
  String get fileCustomSize => 'Personalizado…';

  @override
  String get fileSizeMb => 'Tamaño en MB';

  @override
  String get fileDownloading => 'Descargando';

  @override
  String get fileRequestingResend => 'Pidiendo el archivo al remitente…';

  @override
  String get fileResuming => 'Reanudando…';

  @override
  String get fileGoneAskResend =>
      'El remitente ya no tiene este archivo: pídele que lo envíe otra vez.';

  @override
  String get fileReofferFailed =>
      'No se pudo obtener el archivo: pide al remitente que lo reenvíe.';

  @override
  String get addIdentityTitle => 'Añadir una identidad';

  @override
  String get addIdentitySubtitle =>
      'La identidad nueva queda oculta en el mismo archivo. La primera vez que añades una, tu identidad actual y la nueva pasan a gestionarse con una contraseña maestra que defines abajo.';

  @override
  String get addIdentityCurrentName => 'Nombre de tu identidad actual';

  @override
  String get addIdentityNewName => 'Nombre de la identidad nueva';

  @override
  String get addIdentityNewPassword => 'Contraseña de la identidad nueva';

  @override
  String get addIdentityMasterPassword => 'Contraseña maestra';

  @override
  String get addIdentityMasterHint =>
      'Abre el selector de identidades. Debe ser distinta de la contraseña propia de cada identidad.';

  @override
  String get addIdentityCreate => 'Crear';

  @override
  String get addIdentityIncomplete => 'Rellena todos los campos.';

  @override
  String get addIdentityClash =>
      'Esa contraseña maestra ya la usa una identidad: elige otra distinta.';

  @override
  String get addIdentityWorking =>
      'Preparando tu identidad nueva…\nPuede tardar unos segundos.';

  @override
  String get addIdentityAnonymous => 'Enrutar de forma anónima';

  @override
  String get addIdentityAnonymousHint =>
      'Oculta la actividad de red de esta identidad a través de la red superpuesta de veil, para que no pueda vincularse con tus otras identidades. Más lento.';

  @override
  String get settingsKeepAllOnline => 'Mantener todas las identidades en línea';

  @override
  String get settingsKeepAllOnlineHint =>
      'Ejecuta a la vez el nodo de cada identidad, así cambiar es instantáneo y ninguna se queda sin conexión (opción predeterminada). Desactívalo para una desvinculación estricta: quien observe puede relacionar las identidades siempre activas por el dispositivo que comparten. Marca las identidades sensibles para que se enruten de forma anónima.';

  @override
  String get settingsPhraseStatusTitle => 'Frase de recuperación';

  @override
  String get settingsPhraseBackedHint =>
      'Esta identidad deriva de su frase de recuperación: la frase que anotaste la restaura.';

  @override
  String get settingsPhraseNoneHint =>
      'Esta identidad se creó sin frase de recuperación, así que ninguna frase puede restaurarla. Haz copias de los datos de la aplicación por otros medios.';

  @override
  String get settingsAnonymousRouting => 'Enrutado anónimo (onion)';

  @override
  String get settingsAnonymousEnabledHint =>
      'ahora se enruta por onion; se aplica en su próximo arranque';

  @override
  String get settingsAnonymousDisabledHint =>
      'ya no se enruta por onion; se aplica en su próximo arranque';

  @override
  String get settingsLazyMining => 'Minado lento (aumentar la confianza)';

  @override
  String get settingsLazyMiningEnabledHint =>
      'acumula dificultad antisybil adicional en segundo plano; gasta CPU y se aplica en su próximo arranque';

  @override
  String get settingsLazyMiningDisabledHint =>
      'desactivado: sin acumulación de dificultad en segundo plano (recomendado); se aplica en su próximo arranque';

  @override
  String get settingsManageIdentities => 'Gestionar las identidades';

  @override
  String get manageTitle => 'Gestionar las identidades';

  @override
  String get manageActive => 'activa';

  @override
  String get manageAnonOn => 'Enrutar de forma anónima';

  @override
  String get manageAnonOff => 'Dejar de enrutar de forma anónima';

  @override
  String get manageBind => 'Vincular una identidad existente';

  @override
  String get manageBindHint =>
      'Añade a esta maestra una identidad que ya tienes';

  @override
  String get manageBindBody =>
      'Introduce la contraseña propia de la identidad para añadirla a esta maestra. La identidad se comparte, no se copia: sigue siendo accesible también con su propia contraseña.';

  @override
  String get manageBindPassword => 'Contraseña de la identidad';

  @override
  String get manageBindLabel => 'Nombre dentro de esta maestra';

  @override
  String get manageBindError =>
      'No se pudo vincular: contraseña incorrecta, es una maestra, o ese nombre o identidad ya está aquí.';

  @override
  String get manageUnbind => 'Desvincular de esta maestra';

  @override
  String get manageUnbindBody =>
      'Quita esta identidad solo de esta maestra. Su espacio NO se elimina: sigue abriéndose con su propia contraseña y desde cualquier otra maestra que la incluya.';

  @override
  String get manageUnbindLastError =>
      'No se puede desvincular la última identidad. Elimínala o borra todos los datos.';

  @override
  String get manageDelete => 'Eliminar la identidad';

  @override
  String get manageDeleteBody =>
      'Borra esta identidad de forma permanente e irreversible: sus claves, contactos, mensajes y archivos se limpian del contenedor. Esto no se puede deshacer.';

  @override
  String get manageDeleteLastError =>
      'No se puede eliminar la última identidad. Usa «Borrar todos los datos» para quitarlo todo.';

  @override
  String get settingsDecoyMaster => 'Configurar el acceso señuelo';

  @override
  String get decoyTitle => 'Acceso señuelo (bajo coacción)';

  @override
  String get decoySubtitle =>
      'Una contraseña aparte que, bajo coacción, abre solo las identidades que marques abajo. Tu maestra real y el resto de identidades siguen ocultas.';

  @override
  String get decoyWarning =>
      'Cualquiera a quien le des esta contraseña verá el contenido COMPLETO de cada identidad que marques. Incluye solo las que sean realmente seguras.';

  @override
  String get decoyPassword => 'Contraseña de coacción';

  @override
  String get decoyInclude => 'Identidades que se mostrarán bajo coacción';

  @override
  String get decoyCreate => 'Crear el acceso señuelo';

  @override
  String get decoyCreated => 'Acceso señuelo creado.';

  @override
  String get decoyPickOne => 'Selecciona al menos una identidad.';

  @override
  String get decoyClash =>
      'Esa contraseña ya está en uso: elige otra distinta.';

  @override
  String get languageSystem => 'Como el sistema';

  @override
  String get chatRequestTitle => 'Este contacto quiere conectar contigo';

  @override
  String get actionAccept => 'Aceptar';

  @override
  String get actionBlock => 'Bloquear';

  @override
  String get actionOpen => 'Abrir';

  @override
  String get inviteAddContact => 'Añadir un contacto';

  @override
  String get inviteShowToContact => 'Enséñale esto a tu contacto';

  @override
  String get inviteTooLarge => 'la invitación es demasiado grande';

  @override
  String get inviteCopied => 'Invitación copiada';

  @override
  String get inviteIsSelf =>
      'Esa es tu propia invitación: no puedes añadirte a ti.';

  @override
  String get inviteCopyMine => 'Copiar mi invitación';

  @override
  String get identityDetails => 'Detalles de la identidad';

  @override
  String get identityPublicKey => 'clave pública';

  @override
  String get identityAlgo => 'algoritmo';

  @override
  String get invitePasteTheirs => 'Pega su invitación';

  @override
  String get inviteScanTooltip => 'Escanear un QR con la cámara';

  @override
  String get scanTitle => 'Escanear una invitación';

  @override
  String get scanHint =>
      'Apunta la cámara al código QR de invitación de tu contacto';

  @override
  String get scanUnavailable =>
      'Cámara no disponible: pega la invitación en su lugar';

  @override
  String get scanNotInvite => 'Ese QR no es una invitación de xVeil';

  @override
  String get scanTorchOn => 'Encender la linterna';

  @override
  String get scanTorchOff => 'Apagar la linterna';

  @override
  String get inviteAddButton => 'Añadir el contacto';

  @override
  String get inviteInvalid => 'Esa no es una invitación válida de xVeil';

  @override
  String get networkRouteTitle => 'Enrutar el tráfico (proxy o VPN)';

  @override
  String get networkRouteSubActive => 'Enrutado activo';

  @override
  String get networkRouteSubIdle => 'Enruta tu tráfico a través de veil';

  @override
  String get routeTitle => 'Enrutar el tráfico';

  @override
  String get routeSocks5Title => 'Enrutar mi tráfico (SOCKS5)';

  @override
  String get routeSocks5Hint =>
      'Abre un proxy SOCKS5 local y túnela su tráfico por veil hasta un nodo de salida. Apunta ahí un navegador o el proxy del sistema para eludir la censura y ocultar tu ubicación.';

  @override
  String get routeListenLabel => 'Dirección SOCKS5 local';

  @override
  String get routeListenHint =>
      'Solo loopback (por ejemplo, 127.0.0.1:1080): mantiene el proxy privado a este dispositivo.';

  @override
  String get routeListenInvalid =>
      'Usa un host:puerto de loopback, por ejemplo 127.0.0.1:1080';

  @override
  String get routeExitNodeLabel => 'Identificador del nodo de salida (64 hex)';

  @override
  String get routeExitNodeHint =>
      'node_id de una salida en la que confíes; por ejemplo, uno de tus propios nodos de «Mis nodos».';

  @override
  String get routeExitNodeInvalid =>
      'Debe ser un node_id hexadecimal de 64 caracteres';

  @override
  String get routeNeedExit =>
      'Indica el identificador de un nodo de salida por el que enrutar';

  @override
  String routeProxyAddress(String addr) {
    return 'Apunta tus aplicaciones o tu navegador a $addr';
  }

  @override
  String get routeServeTitle => 'Ser un nodo de salida';

  @override
  String get routeServeHint =>
      'Permite que otros pares saquen su tráfico a internet a través de este nodo. Cuantas más salidas, más resistente a la censura es la red, pero el tráfico parecerá originarse en este dispositivo.';

  @override
  String get routeAllowPrivate => 'Permitir redes privadas (avanzado)';

  @override
  String get routeAllowPrivateHint =>
      'Deja que la salida alcance direcciones loopback, RFC1918 o link-local. DESACTÍVALO en cualquier salida pública: impide llegar a servicios internos y a los puntos de metadatos de la nube.';

  @override
  String get routeAppliesNextStart =>
      'Los cambios se aplican la próxima vez que arranque el nodo.';

  @override
  String get vpnTitle => 'VPN del sistema';

  @override
  String get vpnHint =>
      'Enruta el tráfico del dispositivo por una salida de veil. La VPN arranca sola su transporte SOCKS5 local; el interruptor SOCKS5 aparte es solo para usar el proxy directamente.';

  @override
  String get vpnStatusRunning => 'Túnel de paquetes activo';

  @override
  String get vpnStatusStarting => 'Arrancando el túnel de paquetes…';

  @override
  String get vpnStatusStopping => 'Deteniendo el túnel de paquetes…';

  @override
  String get vpnStatusStopped => 'Túnel de paquetes detenido';

  @override
  String get vpnStatusError => 'Error del túnel de paquetes';

  @override
  String get vpnStatusUnsupported =>
      'El túnel de paquetes no está disponible en esta versión';

  @override
  String get vpnUnsupportedDetail =>
      'Esta versión de la plataforma todavía no tiene motor nativo de túnel de paquetes. SOCKS5 sigue disponible; xVeil no afirmará que hay una VPN activa.';

  @override
  String get vpnRouteMode => 'Selección del tráfico';

  @override
  String get vpnRouteAll => 'Todo el tráfico';

  @override
  String get vpnRouteInclude => 'Solo las subredes seleccionadas';

  @override
  String get vpnRouteExclude => 'Todo excepto las subredes seleccionadas';

  @override
  String get vpnApplicationRouting => 'Aplicaciones que usan la VPN';

  @override
  String get vpnApplicationAll => 'Todas las aplicaciones';

  @override
  String get vpnApplicationOnlySelected =>
      'Solo las aplicaciones seleccionadas';

  @override
  String get vpnApplicationOnlySelectedHint =>
      'Solo las aplicaciones de Android seleccionadas entran en el túnel; el resto usa la red normal.';

  @override
  String get vpnApplicationUnsupported =>
      'El enrutado por aplicación está disponible en Android. Las VPN de consumo de iOS y macOS no exponen la aplicación de origen; Linux y Windows necesitan un futuro backend de enrutado por proceso.';

  @override
  String get vpnApplicationSelect => 'Seleccionar aplicaciones';

  @override
  String get vpnApplicationNoneSelected => 'Selecciona al menos una aplicación';

  @override
  String vpnApplicationSelectedCount(Object count) {
    return '$count aplicaciones seleccionadas';
  }

  @override
  String get vpnApplicationPickerTitle => 'Aplicaciones que usan la VPN';

  @override
  String get vpnApplicationPickerEmpty =>
      'Android no ve ninguna aplicación que se pueda abrir.';

  @override
  String get vpnApplicationSearchEmpty =>
      'Ninguna aplicación coincide con esta búsqueda.';

  @override
  String vpnApplicationLoadError(Object error) {
    return 'No se pudieron listar las aplicaciones: $error';
  }

  @override
  String get oproxyCatalogTitle => 'Salidas oproxy';

  @override
  String get oproxyAddTitle => 'Añadir un oproxy';

  @override
  String get oproxyEditTitle => 'Editar el oproxy';

  @override
  String get oproxyName => 'Nombre';

  @override
  String get oproxyEmpty => 'Añade antes al menos una salida oproxy.';

  @override
  String get oproxyNoDefault =>
      'No hay ningún oproxy predeterminado configurado';

  @override
  String oproxyDefaultSummary(Object count) {
    return 'Cadena predeterminada: $count salidas';
  }

  @override
  String get oproxyDefaultOrderTitle => 'Oproxy predeterminado y alternativas';

  @override
  String get oproxyDefaultOrderAction =>
      'Configurar el predeterminado y las alternativas';

  @override
  String get oproxyPrimary => 'Oproxy principal';

  @override
  String get oproxyUseDefault => 'Usar la cadena predeterminada';

  @override
  String get oproxyVpnRouteTitle => 'Cadena oproxy principal de la VPN';

  @override
  String oproxyRouteSummary(Object fallbacks, Object primary) {
    return '$primary + $fallbacks alternativas';
  }

  @override
  String get oproxyAutoFailover => 'Conmutación automática de oproxy';

  @override
  String get oproxyAutoFailoverHint =>
      'Las conexiones nuevas prueban la siguiente salida cuando la principal no consigue abrir ruta. Las conexiones existentes se quedan en su salida actual.';

  @override
  String get oproxyApplicationRoutesTitle => 'Rutas oproxy por aplicación';

  @override
  String get oproxyApplicationRoutesEmpty =>
      'No hay aplicaciones seleccionadas para esta VPN.';

  @override
  String oproxyApplicationRoutesCount(Object count) {
    return '$count excepciones por aplicación';
  }

  @override
  String get vpnIncludedCidrs => 'Subredes incluidas';

  @override
  String get vpnExcludedCidrs => 'Subredes excluidas';

  @override
  String get vpnCidrsHint =>
      'Un CIDR IPv4 o IPv6 por línea, por ejemplo 10.20.0.0/16';

  @override
  String get vpnCidrsInvalid => 'Cada ruta debe ser un CIDR IPv4 o IPv6 válido';

  @override
  String get vpnIncludedCountries => 'Países enrutados por la VPN (GeoIP)';

  @override
  String get vpnExcludedCountries => 'Países que evitan la VPN (GeoIP)';

  @override
  String get vpnCountriesHint =>
      'Códigos de país de dos letras separados por espacios o comas, por ejemplo KZ, RU. Usa la instantánea de IPdeny incluida; el GeoIP es aproximado.';

  @override
  String get vpnCountriesInvalid =>
      'Usa códigos de país de dos letras, como KZ';

  @override
  String get vpnRouteDns => 'Enrutar el DNS por la VPN';

  @override
  String get vpnRouteDnsHint =>
      'Instala los servidores DNS elegidos en la interfaz del túnel para evitar fugas del resolvedor.';

  @override
  String get vpnDnsServers => 'Servidores DNS';

  @override
  String get vpnDnsHint => 'Una dirección IPv4 o IPv6 por línea';

  @override
  String get vpnDnsInvalid => 'Cada servidor DNS debe ser una dirección IP';

  @override
  String get vpnAllowLan => 'Permitir la red local';

  @override
  String get vpnAllowLanHint =>
      'Mantiene accesibles las subredes privadas y link-local fuera del túnel.';

  @override
  String get vpnMtu => 'MTU del túnel';

  @override
  String get vpnMtuHint =>
      'Entre 1280 y 9000; 1280 es seguro tanto en rutas IPv4 como IPv6';

  @override
  String get vpnMtuInvalid => 'La MTU debe estar entre 1280 y 9000';

  @override
  String get vpnNeedsProxy =>
      'Elige antes un nodo de salida válido. La VPN arranca sola su transporte SOCKS5.';

  @override
  String get vpnStart => 'Iniciar la VPN';

  @override
  String get vpnStop => 'Detener la VPN';

  @override
  String get networkNodesTitle => 'Mis nodos';

  @override
  String get networkNodesSub => 'Añade un nodo por SSH, ejecuta ogate u oproxy';

  @override
  String networkNodesSubCount(int count) {
    return '$count nodos';
  }

  @override
  String get nodesTitle => 'Mis nodos';

  @override
  String get nodesEmpty => 'Todavía no hay nodos';

  @override
  String get nodesEmptyHint =>
      'Añade un servidor tuyo como salida o relé y luego enruta tu tráfico por él desde «Enrutar el tráfico».';

  @override
  String get nodesAdd => 'Añadir un nodo';

  @override
  String get nodesAddChoiceTitle => '¿Qué tipo de nodo vas a añadir?';

  @override
  String get nodesAddExisting => 'Añadir un nodo existente';

  @override
  String get nodesAddExistingHint =>
      'Registra un nodo que ya está instalado y tiene identificador.';

  @override
  String get nodesAddExistingFieldsHint =>
      'Obligatorios: la etiqueta y el identificador del nodo. Los campos de SSH son opcionales y solo hacen falta para gestionar el servidor. Abajo puedes guardar una contraseña o una clave en el almacenamiento cifrado de xVeil.';

  @override
  String get nodesBootstrapNew => 'Instalar un nodo nuevo por SSH';

  @override
  String get nodesBootstrapNewHint =>
      'Instala veil en un servidor Linux; su identificador de nodo se guardará automáticamente.';

  @override
  String get nodesBootstrapFieldsHint =>
      'Obligatorios: la etiqueta, el host SSH y el usuario SSH. El puerto es 22 de forma predeterminada. Abajo puedes guardar una contraseña o una clave; el identificador del nodo se guarda tras la instalación.';

  @override
  String get nodesBootstrapContinue => 'Continuar con la instalación';

  @override
  String get nodeEdit => 'Editar el nodo';

  @override
  String get nodeLabelLabel => 'Etiqueta *';

  @override
  String get nodeLabelRequired => 'Escribe una etiqueta';

  @override
  String get nodeIdLabel => 'Identificador del nodo (64 hex, opcional)';

  @override
  String get nodeIdRequiredLabel => 'Identificador del nodo (64 hex) *';

  @override
  String get nodeIdHintText =>
      'El identificador veil del nodo: permite enrutar tu tráfico a través de él.';

  @override
  String get nodeIdInvalid =>
      'Debe ser un identificador hexadecimal de 64 caracteres';

  @override
  String get nodeIdRequired =>
      'Escribe el identificador de 64 caracteres del nodo existente';

  @override
  String get nodeSshHostLabel => 'Host SSH (opcional)';

  @override
  String get nodeSshHostRequiredLabel => 'Host SSH *';

  @override
  String get nodeSshHostRequired => 'Escribe el host SSH del servidor nuevo';

  @override
  String get nodeSshPortLabel => 'Puerto SSH (22 de forma predeterminada)';

  @override
  String get nodeSshUserLabel => 'Usuario SSH (opcional)';

  @override
  String get nodeSshUserRequiredLabel => 'Usuario SSH *';

  @override
  String get nodeSshUserRequired => 'Escribe el usuario SSH del servidor nuevo';

  @override
  String get actionSave => 'Guardar';

  @override
  String get nodeRemove => 'Quitar el nodo';

  @override
  String get nodeRemoveConfirm =>
      '¿Quitar este nodo de tu lista? El servidor remoto no se toca.';

  @override
  String get nodeUseAsExit => 'Usar como salida de enrutado';

  @override
  String get nodeUseAsExitDone => 'Definido como tu salida de enrutado SOCKS5';

  @override
  String get nodeNeedsNodeId =>
      'Añade el identificador del nodo para enrutar a través de él';

  @override
  String get nodeProvision => 'Instalar el nodo veil por SSH';

  @override
  String get nodeManage => 'Gestionar el nodo';

  @override
  String get nodeInventory => 'Inspeccionar la instalación y el estado';

  @override
  String get nodeInstallUpdate => 'Instalar o actualizar el software';

  @override
  String get nodeServices => 'Servicios';

  @override
  String get nodeAdvancedConfig => 'Configuración avanzada';

  @override
  String get nodeServiceStatus => 'Estado';

  @override
  String get nodeServiceStart => 'Iniciar';

  @override
  String get nodeServiceStop => 'Detener';

  @override
  String get nodeServiceRestart => 'Reiniciar';

  @override
  String get nodeServiceEnable => 'Activar e iniciar';

  @override
  String get nodeServiceDisable => 'Detener y desactivar';

  @override
  String get nodeConfigLoad => 'Cargar desde el servidor';

  @override
  String get nodeConfigApply => 'Validar, aplicar y reiniciar';

  @override
  String get nodeConfigNotLoaded =>
      'Carga la configuración actual del servidor antes de editarla.';

  @override
  String get nodeUninstallSoftware =>
      'Desinstalar el software (conservar los datos)';

  @override
  String get nodeDebootstrap =>
      'Desinstalar por completo el nodo (borrarlo todo)';

  @override
  String get nodeDebootstrapConfirm =>
      'Esto elimina de forma permanente la identidad del nodo remoto, su estado, sus configuraciones y todo el software de veil, ogate y oproxy. Escribe DELETE para continuar.';

  @override
  String get nodeDebootstrapType => 'Escribe DELETE';

  @override
  String get nodeOperationOutput => 'Salida del servidor';

  @override
  String get nodeOperationRun => 'Ejecutar el comando';

  @override
  String get nodeSelectServices => 'Seleccionar servicios';

  @override
  String get provisionTitle => 'Instalar por SSH';

  @override
  String get provisionReleaseSection => 'Versión de veil-cli';

  @override
  String get provisionReleaseTarget => 'Arquitectura del servidor';

  @override
  String get provisionReleaseTargetX64 => 'Linux x86_64 (musl portátil)';

  @override
  String get provisionReleaseTargetArm64 => 'Linux ARM64 (musl portátil)';

  @override
  String get provisionReleaseRefresh => 'Actualizar los campos de GitHub';

  @override
  String get provisionSourceGithub => 'Versión de GitHub';

  @override
  String get provisionSourceCustom => 'Enlace personalizado';

  @override
  String get provisionReleaseLoading =>
      'Cargando la última versión desde GitHub…';

  @override
  String provisionReleaseLoaded(String tag) {
    return 'Versión de GitHub $tag cargada';
  }

  @override
  String provisionReleaseError(String error) {
    return 'No se pudo rellenar automáticamente desde GitHub: $error. Puedes escribir ambos valores a mano.';
  }

  @override
  String get provisionReleaseUrl => 'URL de la versión de veil-cli';

  @override
  String get provisionReleaseHint =>
      'Se rellena automáticamente desde la versión oficial de GitHub de veilnetwork/veil. Elige «Enlace personalizado» para cambiarla.';

  @override
  String get provisionCustomReleaseHint =>
      'Escribe un enlace HTTPS directo a tu binario. También tienes que indicar su SHA-256 abajo.';

  @override
  String get provisionSha256 => 'SHA-256 de veil-cli';

  @override
  String get provisionSha256Hint =>
      'Obligatorio. El SHA-256 de 64 caracteres hexadecimales publicado junto a ese binario. Si la descarga no coincide, la instalación se aborta en el servidor: esto es lo que impide que un binario manipulado se ejecute como root.';

  @override
  String get provisionRunExit =>
      'Funcionar como salida (enrutar mi tráfico por él)';

  @override
  String get provisionComponents => 'Componentes';

  @override
  String get provisionTransports => 'Transportes entrantes';

  @override
  String get provisionTransportObfs4TcpHint =>
      'Escucha TCP ofuscada para conexiones entre pares resistentes a la censura.';

  @override
  String get provisionTransportTcpHint =>
      'Escucha TCP simple, sin cifrado de transporte.';

  @override
  String get provisionTransportTlsHint =>
      'Escucha TCP protegida por el certificado TLS compartido de abajo.';

  @override
  String get provisionTransportQuicHint =>
      'Escucha QUIC sobre UDP, protegida por el certificado TLS compartido de abajo.';

  @override
  String get provisionTransportWsHint =>
      'WebSocket sin cifrar. Sin certificado, así que sobrevive a un proxy HTTP pero no a un observador: ponlo detrás de un frontal TLS o usa mejor wss.';

  @override
  String get provisionTransportWssHint =>
      'Escucha WebSocket segura, protegida por el certificado TLS compartido de abajo.';

  @override
  String provisionTransportPort(String transport) {
    return 'Puerto de $transport';
  }

  @override
  String provisionTransportNetwork(String protocol) {
    return 'Protocolo de red: $protocol';
  }

  @override
  String get provisionTransportCommon => 'Ajustes de transporte compartidos';

  @override
  String get provisionTransportCommonHint =>
      'Estos valores se aplican a todos los transportes entrantes seleccionados.';

  @override
  String get provisionAdvertiseHost => 'Host o IP pública (opcional)';

  @override
  String get provisionAdvertiseHostHint =>
      'Se anuncia la misma dirección pública para todos los transportes seleccionados; cada uno conserva su propio puerto.';

  @override
  String get provisionTlsShared => 'Certificado TLS';

  @override
  String provisionTlsSharedHint(String transports) {
    return 'Lo usan: $transports. Elige cómo se le entrega el certificado a cada transporte TLS seleccionado.';
  }

  @override
  String get provisionTlsMode => 'Origen del certificado';

  @override
  String get provisionTlsModeExisting => 'Archivos existentes';

  @override
  String get provisionTlsModeAutomatic => 'Automático';

  @override
  String get provisionTlsModeSelfSigned => 'Autofirmado';

  @override
  String get provisionTlsAutomaticName => 'Dominio o IP (sustitución opcional)';

  @override
  String get provisionTlsAutomaticNameHint =>
      'Déjalo vacío para usar el host o la IP pública de arriba. Un nombre DNS obtiene Let\'s Encrypt; una IP obtiene un certificado autofirmado con un SAN de IP.';

  @override
  String get provisionTlsLetsEncryptHint =>
      'Let\'s Encrypt se solicitará en el servidor. El dominio debe apuntar a este servidor y el puerto TCP 80 de entrada debe estar abierto. La renovación se configura automáticamente.';

  @override
  String get provisionTlsIpHint =>
      'Una dirección IP no puede usar aquí el flujo estándar de Let\'s Encrypt. En el servidor se generará un certificado autofirmado con esta IP en su SAN.';

  @override
  String get provisionTlsUnknownHint =>
      'Escribe aquí un dominio o una IP, o indica arriba el host o la IP pública.';

  @override
  String get provisionTlsEmail => 'Correo de la cuenta de Let\'s Encrypt';

  @override
  String get provisionTlsAgreeTerms =>
      'Acepto las condiciones del servicio de Let\'s Encrypt';

  @override
  String get provisionTlsSelfSignedName => 'Dominio o IP del certificado';

  @override
  String get provisionTlsSelfSignedNameHint =>
      'El valor se escribe en el nombre alternativo del sujeto (DNS o IP) del certificado.';

  @override
  String get provisionTlsSelfSignedDays => 'Validez en días (1–3650)';

  @override
  String get provisionTlsSelfSignedHint =>
      'Los clientes tienen que confiar en este certificado autofirmado de forma explícita. Su clave privada se genera y se queda en el servidor.';

  @override
  String get provisionTlsCert => 'Ruta remota del certificado TLS';

  @override
  String get provisionTlsKey => 'Ruta remota de la clave privada TLS';

  @override
  String get provisionTlsCa => 'Ruta remota de la CA de TLS (opcional)';

  @override
  String provisionComponentUrl(String component) {
    return 'URL de la versión de $component';
  }

  @override
  String provisionComponentSha(String component) {
    return 'SHA-256 de $component';
  }

  @override
  String get provisionScriptLabel =>
      'Se ejecuta en el servidor como root: revísalo antes de lanzarlo.';

  @override
  String get provisionPskMissing =>
      'Esta versión no incluye la PSK de despliegue, así que el nodo no puede unirse a la red. La instalación no está disponible.';

  @override
  String get provisionRun => 'Ejecutar por SSH';

  @override
  String get provisionRunning =>
      'Instalando… (minar la identidad puede tardar un rato)';

  @override
  String get provisionNeedUrl => 'Escribe una URL https de la versión';

  @override
  String get provisionInvalidConfig =>
      'Revisa los campos obligatorios de versión, transporte, puerto y TLS';

  @override
  String get provisionAddedPeer => 'Servidor añadido a la lista de pares';

  @override
  String provisionPeerFailed(String reason) {
    return 'No se pudo añadir el servidor como par: $reason';
  }

  @override
  String get provisionAddedProxy =>
      'Salida oproxy añadida a la lista de proxies';

  @override
  String get provisionProxyNeedsNodeId =>
      'oproxy se instaló, pero el servidor no devolvió ningún identificador de nodo: no se puede añadir a la lista de proxies';

  @override
  String get provisionSavedNodeId =>
      'Se guardó el identificador de nodo que devolvió el servidor';

  @override
  String get nodeSshConnect => 'Conectar por SSH';

  @override
  String sshDialogTitle(String host) {
    return 'SSH a $host';
  }

  @override
  String get sshUsePassword => 'Contraseña';

  @override
  String get sshUseKey => 'Clave privada';

  @override
  String get sshPasswordLabel => 'Contraseña';

  @override
  String get sshKeyLabel => 'Clave privada (PEM)';

  @override
  String get sshKeyPassphraseLabel => 'Frase de la clave (opcional)';

  @override
  String get sshCredsNotSaved =>
      'Las credenciales que escribas aquí se usan una sola vez. Gestiona las credenciales guardadas en la ficha del nodo.';

  @override
  String get sshCredentialsTitle => 'Autenticación SSH';

  @override
  String get sshSavedPasswordLabel => 'Contraseña SSH guardada (opcional)';

  @override
  String get sshSavedPasswordHint =>
      'Déjalo vacío para quitar la contraseña guardada.';

  @override
  String get sshCredentialsEncryptedHint =>
      'La contraseña y la clave privada se guardan únicamente dentro del contenedor cifrado de xVeil.';

  @override
  String get sshCredentialsEndpointCleared =>
      'El extremo SSH cambió, así que la contraseña y la clave guardadas se borraron por seguridad.';

  @override
  String get sshGenerateEd25519 => 'Generar una clave Ed25519';

  @override
  String get sshRegenerateEd25519 => 'Generar una clave Ed25519 nueva';

  @override
  String get sshSavedEd25519Title => 'Clave Ed25519 guardada';

  @override
  String get sshPublicKeyLabel =>
      'Añade esta línea al archivo ~/.ssh/authorized_keys del servidor:';

  @override
  String get sshCopyPublicKey => 'Copiar la clave pública';

  @override
  String get sshPublicKeyCopied => 'Clave pública copiada';

  @override
  String get sshRemoveSavedKey => 'Quitar la clave guardada';

  @override
  String get sshUseSavedKeyHint =>
      'Déjalo vacío para usar la clave Ed25519 guardada.';

  @override
  String get sshOtherKeyLabel => 'Otra clave privada (PEM, solo esta vez)';

  @override
  String get sshCredentialRequired =>
      'Escribe una contraseña o una clave privada';

  @override
  String get sshCredentialsSaving => 'Guardando…';

  @override
  String sshCredentialsSaveFailed(String error) {
    return 'No se pudieron guardar las credenciales SSH: $error';
  }

  @override
  String nodeRegistrySaveFailed(String error) {
    return 'No se pudo guardar la lista de nodos: $error';
  }

  @override
  String sshKeyGenerationFailed(String error) {
    return 'No se pudo generar la clave: $error';
  }

  @override
  String get sshConnectRun => 'Conectar y comprobar';

  @override
  String get sshConnecting => 'Conectando…';

  @override
  String sshDone(String code) {
    return 'Hecho (salida $code)';
  }

  @override
  String sshError(String err) {
    return 'Falló: $err';
  }

  @override
  String get nodeCheckReachable => 'Comprobar la accesibilidad';

  @override
  String get nodeChecking => 'Comprobando…';

  @override
  String get nodeReachable => 'Accesible';

  @override
  String get nodeUnreachable => 'No accesible';

  @override
  String get networkExtTitle => 'Extensiones (Lua)';

  @override
  String get networkExtSub => 'Cargar complementos en un entorno aislado';

  @override
  String get networkComingLater => 'Llegará en una fase posterior';

  @override
  String get networkStatusError => 'Error';

  @override
  String get networkBackgroundTitle => 'Seguir funcionando en segundo plano';

  @override
  String get networkBackgroundHint =>
      'Solo en Android. Mantiene vivo el nodo —tu proxy y la entrega de mensajes entrantes— después de que salgas de la aplicación. Requiere una notificación permanente (para que se vea que la aplicación está funcionando) y gasta más batería.';

  @override
  String get networkBackgroundAllowTitle =>
      'Permitir el trabajo en segundo plano';

  @override
  String get networkBackgroundAllowBody =>
      'Para que lleguen los mensajes con xVeil en segundo plano, permítele funcionar sin restricciones de batería. En algunos teléfonos (por ejemplo, Xiaomi o Samsung) TAMBIÉN tienes que activar el «Inicio automático» o quitar los límites de batería en los ajustes de la aplicación.';

  @override
  String get networkBackgroundAllowGrant => 'Permitir';

  @override
  String get networkBackgroundOpenSettings => 'Ajustes de la aplicación';

  @override
  String get callBatteryAllowTitle =>
      '¿Mantener las llamadas en segundo plano?';

  @override
  String get callBatteryAllowBody =>
      'Algunos teléfonos cortan la llamada cuando sales de xVeil. Permítele ignorar la optimización de batería para que las llamadas sigan en segundo plano.';

  @override
  String get networkBackgroundLater => 'Más tarde';

  @override
  String get peersTitle => 'Pares conectados';

  @override
  String get peersSectionActive => 'Activos';

  @override
  String get peersSectionInactive => 'Inactivos';

  @override
  String get peersEmpty => 'Todavía no hay pares';

  @override
  String get peersEmptyHint =>
      'Cuando tu nodo se conecte con otros, aparecerán aquí.';

  @override
  String get peerActiveNow => 'activo ahora';

  @override
  String get peerNeverSeen => 'todavía sin conectar';

  @override
  String get peerLastSeenLabel => 'última actividad';

  @override
  String get peerDetailsTitle => 'Detalles del par';

  @override
  String get peerFieldNodeId => 'node_id';

  @override
  String get peerFieldTransport => 'transporte';

  @override
  String get peerFieldState => 'estado';

  @override
  String get peerFieldDirection => 'dirección';

  @override
  String get peerFieldLastSeen => 'última actividad (según este dispositivo)';

  @override
  String get peerStateActive => 'Activo';

  @override
  String get peerStateConnecting => 'Conectando';

  @override
  String get peerStateClosed => 'Desconectado';

  @override
  String get peerStateUnknown => 'Desconocido';

  @override
  String get peerDirInbound => 'Entrante';

  @override
  String get peerDirOutbound => 'Saliente';

  @override
  String get peerDirUnknown => 'Desconocida';

  @override
  String get timeJustNow => 'ahora mismo';

  @override
  String timeMinutesAgo(int n) {
    return 'hace $n min';
  }

  @override
  String timeHoursAgo(int n) {
    return 'hace $n h';
  }

  @override
  String timeDaysAgo(int n) {
    return 'hace $n d';
  }

  @override
  String get peersAddAction => 'Añadir un par';

  @override
  String get peersAddTitle => 'Añadir un par mediante un enlace';

  @override
  String get peersAddHint =>
      'Pega un enlace veil:bootstrap. Un nodo genera el suyo con `veil-cli bootstrap invite`; un servidor ya desplegado lo guarda aquí automáticamente.';

  @override
  String get peersAddFieldLabel => 'Enlace de arranque';

  @override
  String get peersAddPaste => 'Pegar';

  @override
  String peersAddInvalid(String reason) {
    return 'No es un enlace de arranque: $reason';
  }

  @override
  String get peersAddNoTransport =>
      'Este enlace lleva una identidad, pero ninguna dirección, así que no hay adónde llamar. Úsalo para añadir un contacto en su lugar.';

  @override
  String get peersAddNoNode => 'El nodo todavía no está en marcha';

  @override
  String get peersAddDone => 'Par añadido';

  @override
  String peersAddFailed(String reason) {
    return 'No se pudo añadir el par: $reason';
  }

  @override
  String peersAddResolved(String nodeId, String transport) {
    return 'nodo $nodeId… vía $transport';
  }

  @override
  String get peersShareAction => 'Compartir nodos de entrada';

  @override
  String get peersShareTitle => 'Compartir nodos de entrada';

  @override
  String get peersShareSubtitle =>
      'Elige nodos para darle a alguien puntos de entrada que funcionen: útil si donde está bloquean las semillas predeterminadas. Esto comparte SOLO esos nodos, nunca tu identidad.';

  @override
  String get peersShareNone =>
      'No hay nodos de entrada conocidos que compartir';

  @override
  String get peersShareSelectOne => 'Selecciona al menos un nodo';

  @override
  String get peersShareGenerate => 'Generar el enlace';

  @override
  String get peersShareScanHint =>
      'Pídele que lo escanee o que abra el enlace en xVeil';

  @override
  String get peerActiveBadge => 'activo';

  @override
  String peersImported(int n) {
    return 'Se añadieron $n nodos de entrada';
  }

  @override
  String get onboardRepeatPassword => 'Repite la contraseña';

  @override
  String get onboardPasswordTitle => 'Elige una contraseña';

  @override
  String get onboardPasswordSubtitle =>
      'Esta contraseña abre tu espacio en este dispositivo. No hay forma de restablecerla.';

  @override
  String get onboardPasswordTooShort => 'Usa al menos 6 caracteres';

  @override
  String get onboardPasswordMismatch => 'Las contraseñas no coinciden';

  @override
  String get recoveryPhraseHint =>
      'Escribe tu frase de recuperación, con las palabras separadas por espacios';

  @override
  String get securityCenterTooltip => 'Seguridad';

  @override
  String get securityCenterAnonymousOn => 'Esta identidad se enruta por onion';

  @override
  String get securityCenterAnonymousOff =>
      'Esta identidad no se enruta por onion';

  @override
  String get securityCenterTitle => 'Seguridad y red';

  @override
  String get callStartTooltip => 'Llamar';

  @override
  String get callAudio => 'Llamada de voz';

  @override
  String get callVideo => 'Videollamada';

  @override
  String get callScreen => 'Compartir la pantalla';

  @override
  String get callIncoming => 'Llamada entrante';

  @override
  String get callDialing => 'Llamando…';

  @override
  String get callConnecting => 'Conectando…';

  @override
  String get callActive => 'En llamada';

  @override
  String get callAccept => 'Aceptar';

  @override
  String get callDecline => 'Rechazar';

  @override
  String get callEnd => 'Colgar';

  @override
  String get callCancel => 'Cancelar';

  @override
  String get callEnded => 'Llamada finalizada';

  @override
  String get callMicOn => 'Micrófono activado';

  @override
  String get callMicOff => 'Micrófono silenciado';

  @override
  String get callPeerMicOff => 'Silenció su micrófono';

  @override
  String get callCameraOn => 'Cámara activada';

  @override
  String get callCameraOff => 'Cámara apagada';

  @override
  String get callDevices => 'Dispositivos';

  @override
  String get callSettingsAudio => 'Audio';

  @override
  String get callSettingsVideo => 'Vídeo';

  @override
  String get callAudioOutput => 'Salida de audio';

  @override
  String get callSpeaker => 'Altavoz';

  @override
  String get callEarpiece => 'Auricular del teléfono';

  @override
  String get callCameras => 'Cámaras';

  @override
  String get callMicrophones => 'Micrófonos';

  @override
  String get callDisplays => 'Monitores';

  @override
  String get callWindows => 'Ventanas';

  @override
  String get callNoCaptureDevices =>
      'No hay dispositivos de captura disponibles';

  @override
  String get callDeviceSwitchFailed => 'No se pudo cambiar de dispositivo';

  @override
  String get callSwitchCamera => 'Cambiar de cámara';

  @override
  String get callScreenOn => 'Compartiendo la pantalla';

  @override
  String get callScreenOff => 'Compartir la pantalla';

  @override
  String get callScreenWaiting => 'Esperando la pantalla compartida…';

  @override
  String get callScreenPermissionRequired =>
      'Permite la grabación de pantalla para xveil en los Ajustes del sistema y vuelve a intentarlo';

  @override
  String get callOpenScreenSettings => 'Abrir los Ajustes';

  @override
  String get groupCallOngoing => 'Llamada de grupo en curso';

  @override
  String get groupCallJoinAction => 'Unirse';

  @override
  String get callVideoPaused => 'Vídeo en pausa';

  @override
  String get callVideoWaiting => 'Esperando el vídeo…';

  @override
  String get callPathOnion => 'Anónima (onion)';

  @override
  String get callPathRelay => 'Por relé';

  @override
  String get callPathP2P => 'Directa (P2P)';

  @override
  String get callPathNoDirectSession => 'sin enlace directo';

  @override
  String get groupCallTitle => 'Llamada de grupo';

  @override
  String get groupCallIncoming => 'Llamada de grupo entrante';

  @override
  String get groupCallStartAudio => 'Iniciar una llamada de grupo de voz';

  @override
  String get groupCallStartVideo => 'Iniciar una videollamada de grupo';

  @override
  String get groupCallBusy => 'Ya hay otra llamada activa';

  @override
  String get groupCallLeave => 'Salir de la llamada';

  @override
  String get groupCallEndEveryone => 'Finalizar para todos';

  @override
  String get groupCallMinimize => 'Minimizar la llamada de grupo';

  @override
  String get groupCallExpand => 'Abrir la llamada de grupo';

  @override
  String get settingsNickname => 'Apodo';

  @override
  String get settingsNicknameHint =>
      'Reserva un @nombre por el que puedan encontrarte';

  @override
  String get videoPlayError => 'No se pudo reproducir este vídeo';

  @override
  String get videoPlayUnsupported =>
      'Este formato no se puede reproducir aquí. En Linux solo se reproducen vídeos WebM (VP8).';

  @override
  String get emojiSearchHint => 'Buscar emoji';

  @override
  String get chatEmojiTooltip => 'Emoji';

  @override
  String get chatMoreActions => 'Más acciones';

  @override
  String get composerCamera => 'Cámara';

  @override
  String get composerUploadPhoto => 'Subir una foto';

  @override
  String get composerUploadVideo => 'Subir un vídeo';

  @override
  String get composerUploadFile => 'Subir un archivo';

  @override
  String get composerPoll => 'Encuesta';

  @override
  String get composerLocation => 'Ubicación';

  @override
  String get composerPlanned => 'Previsto';

  @override
  String get composerGif => 'GIF';

  @override
  String get composerGifLocal => 'Elegir un GIF del dispositivo';

  @override
  String get composerGifPrivacy =>
      'Sin búsqueda externa de GIF: tu consulta nunca sale de xVeil.';

  @override
  String get composerCameraUnavailable =>
      'La captura con la cámara no está disponible en este dispositivo';

  @override
  String get nicknameTitle => 'Apodo';

  @override
  String get nicknameIntro =>
      'Un apodo es un @nombre público en la red veil que apunta a esta identidad. Reservarlo cuesta prueba de trabajo: los nombres cortos cuestan mucho más. Un nombre puede arrebatarse con estrictamente más trabajo, así que puedes reforzar el tuyo cuando quieras.';

  @override
  String get nicknameFieldLabel => 'Nombre (a–z, 0–9, _)';

  @override
  String get nicknameCheck => 'Comprobar la disponibilidad';

  @override
  String get nicknameFree => 'Disponible';

  @override
  String get nicknameMineVerdict => 'Ya es tuyo';

  @override
  String nicknameTakenWeight(String weight) {
    return 'Ocupado: peso de protección $weight';
  }

  @override
  String get nicknameClaim => 'Reservar el nombre';

  @override
  String get nicknameMiningLabel => 'Minando la prueba de trabajo…';

  @override
  String nicknameMiningStats(String weight, String target, String hashes) {
    return 'peso $weight / $target · $hashes hashes';
  }

  @override
  String get nicknamePublishing => 'Publicando…';

  @override
  String get nicknameWeightExplain =>
      'El peso de protección es la prueba de trabajo acumulada que sostiene el nombre; el valor mostrado es el peso actual en la red. Arrebatarlo exige estrictamente más trabajo, y reforzarlo sube ese precio.';

  @override
  String nicknameOwnedTakenOver(String weight) {
    return 'Alguien se quedó con el nombre aportando más trabajo (peso rival $weight). Refuérzalo para recuperarlo minando estrictamente más.';
  }

  @override
  String nicknameOwnedWeight(String weight) {
    return 'Peso de protección $weight';
  }

  @override
  String get nicknameTopUp => 'Reforzar (minar más)';

  @override
  String get nicknameClaimed => 'Nombre publicado';

  @override
  String get nicknameNotFound => 'No se encontró el nombre en la red';

  @override
  String get nicknameIsSelf => 'Ese nombre apunta a ti';

  @override
  String get nicknameOwnerChanged =>
      'Este nombre ha cambiado de dueño en la red. El contacto sigue apuntando a la persona que añadiste.';

  @override
  String get settingsDevices => 'Mis dispositivos';

  @override
  String get settingsDevicesHint =>
      'Vincula, revisa o revoca los dispositivos que comparten esta identidad';

  @override
  String get devicesThisDevice => 'Este dispositivo';

  @override
  String get devicesNoGroup => 'Todavía no hay otros dispositivos vinculados';

  @override
  String get devicesLinkNew => 'Vincular un dispositivo nuevo';

  @override
  String get devicesJoinExisting => 'Unirse a un dispositivo existente';

  @override
  String get devicesPhrase => 'Frase de recuperación';

  @override
  String get devicesPhraseHint =>
      'La frase descifra la clave soberana solo para esta acción. No se guarda.';

  @override
  String get devicesRecoveryCode => 'Código de recuperación';

  @override
  String get devicesRecoveryCodeHint =>
      'El código descifra el certificado de recuperación solo para esta acción. No se guarda.';

  @override
  String get devicesTargetInvite => 'Invitación del dispositivo nuevo';

  @override
  String get devicesTargetInviteHint =>
      'Escanea o pega la invitación de arranque que muestra el dispositivo nuevo';

  @override
  String get devicesShowMyInvite =>
      'Primero, enséñale esta invitación al dispositivo que ya tienes';

  @override
  String get devicesPrepare => 'Preparar el enlace seguro';

  @override
  String get devicesAdoptionQrTitle => 'Escanea esto en el dispositivo nuevo';

  @override
  String get devicesAdoptionQrHint =>
      'Primero escanea allí este código de configuración. Después vuelve aquí y envía la configuración cifrada.';

  @override
  String get devicesQrTooLarge =>
      'Este código es demasiado largo para mostrarse como código QR. Cópialo y pégalo en el otro dispositivo, o envía la configuración cifrada por la red.';

  @override
  String get devicesSendSetup =>
      'El dispositivo nuevo está listo: enviar configuración';

  @override
  String get devicesSetupSent => 'Configuración cifrada enviada';

  @override
  String get devicesJoinToken =>
      'Código de configuración del dispositivo existente';

  @override
  String get devicesJoinTokenHint =>
      'Escanea o pega el código de configuración del dispositivo';

  @override
  String get devicesWaitTitle => 'Listo para recibir';

  @override
  String get devicesWaitHint =>
      'En el dispositivo existente, pulsa «enviar configuración». Esta pantalla terminará automáticamente.';

  @override
  String get devicesJoined => 'Dispositivo vinculado';

  @override
  String get devicesInvalidToken =>
      'Código de configuración no válido o que no coincide';

  @override
  String get devicesExpiredToken => 'Este código de configuración ha caducado';

  @override
  String get devicesRevoke => 'Revocar dispositivo';

  @override
  String devicesRevokeTitle(String device) {
    return 'Revoke $device?';
  }

  @override
  String get devicesRelinkRevoked =>
      'Este dispositivo fue revocado. Su clave antigua ya no es de confianza: restablece el dispositivo y vincúlalo con una clave nueva.';

  @override
  String get devicesRevokeKeyStillCertified =>
      'No revocado: el documento de identidad aún certifica la clave de este dispositivo. Inténtalo de nuevo con la credencial propietaria de la identidad.';

  @override
  String get devicesDocumentNotAmended =>
      'No vinculado: no se pudo actualizar el documento de identidad, así que el dispositivo quedó fuera. Inténtalo con la credencial propietaria de esta identidad.';

  @override
  String get devicesOperationFailed =>
      'No se pudo completar la vinculación del dispositivo';

  @override
  String get devicesCancelPending => 'Cancelar la espera';

  @override
  String get devicesRecoverySection => 'Todos los dispositivos perdidos';

  @override
  String get devicesCreateRecovery => 'Crear certificado de recuperación';

  @override
  String get devicesCreateRecoveryHint =>
      'Conserva el mismo ID de nodo soberano si se pierden todos los dispositivos vinculados';

  @override
  String get devicesRecover => 'Recuperar el registro de dispositivos';

  @override
  String get devicesRecoverHint =>
      'Usa un certificado y su código de recuperación, guardado aparte, en un registro nuevo';

  @override
  String get devicesCertificate => 'Certificado de recuperación';

  @override
  String get devicesCertificateHint =>
      'Pega el valor xveil-recovery:v1 completo';

  @override
  String get devicesCertificateReady => 'Certificado de recuperación creado';

  @override
  String get devicesCertificateWarning =>
      'Quien tenga ambos valores controla tu identidad soberana de dispositivo. Guarda el certificado y el código por separado. El código solo se muestra ahora.';

  @override
  String get devicesCopyCertificate => 'Copiar certificado';

  @override
  String get devicesCopyCode => 'Copiar código de recuperación';

  @override
  String devicesCertificateCopiedClears(int seconds) {
    return 'Certificado copiado. El portapapeles se borrará en $seconds segundos.';
  }

  @override
  String devicesCodeCopiedClears(int seconds) {
    return 'Código de recuperación copiado. El portapapeles se borrará en $seconds segundos.';
  }

  @override
  String devicesTokenCopiedClears(int seconds) {
    return 'Token de configuración copiado. El portapapeles se borrará en $seconds segundos.';
  }

  @override
  String get devicesRecovered =>
      'Registro de dispositivos recuperado con el mismo ID de nodo soberano';

  @override
  String get devicesFreshRegistryRequired =>
      'La recuperación requiere un registro de dispositivos nuevo';

  @override
  String get actionReject => 'Reject';

  @override
  String cloudDocumentInvites(int count) {
    return 'Invitaciones a documentos compartidos ($count)';
  }

  @override
  String cloudDocumentInviteFrom(String sender) {
    return 'Invitación de $sender';
  }

  @override
  String cloudDocumentInviteKind(String kind) {
    return 'Documento $kind cifrado · inactivo hasta que se acepte';
  }

  @override
  String get cloudDocumentAdopted => 'Documento compartido añadido';

  @override
  String get cloudDocumentAdoptFailed => 'No se pudo verificar la invitación';

  @override
  String get cloudDocumentRejected => 'Invitación eliminada';

  @override
  String get cloudSharedNew => 'Nuevo documento compartido';

  @override
  String cloudSharedDocuments(int count) {
    return 'Documentos compartidos ($count)';
  }

  @override
  String cloudSharedDocument(String kind, String id) {
    return 'Shared $kind · $id';
  }

  @override
  String cloudSharedMembers(int count, int epoch, String role) {
    return '$count members · epoch $epoch · $role';
  }

  @override
  String get cloudSharedPickContact => 'Invitar a un contacto aceptado';

  @override
  String get cloudSharedRole => 'Rol en el documento';

  @override
  String get cloudSharedRoleOwner => 'Owner';

  @override
  String get cloudSharedRoleEditor => 'Editor';

  @override
  String get cloudSharedRoleViewer => 'Viewer';

  @override
  String get cloudSharedCreated =>
      'Documento compartido creado e invitación en cola';

  @override
  String get cloudSharedFailed =>
      'No se pudo actualizar el documento compartido';

  @override
  String get cloudSharedPartial =>
      'Guardado localmente, pero el envío no se puso en cola para todos los miembros';

  @override
  String get cloudSharedAddMember => 'Añadir miembro';

  @override
  String get cloudSharedRevoke => 'Revocar acceso';

  @override
  String cloudSharedRevokeTitle(String member) {
    return '¿Revocar el acceso de $member?';
  }

  @override
  String get cloudSharedRotate => 'Rotar la clave de cifrado';

  @override
  String get cloudSharedRotateTitle =>
      '¿Rotar la clave del documento para todos los miembros?';

  @override
  String get cloudSharedCompact => 'Compactar el historial';

  @override
  String get cloudSharedCompactTitle =>
      '¿Pedir a los editores actuales que confirmen el estado sincronizado exacto y sustituir después automáticamente el historial cifrado antiguo por un punto de control firmado? Los editores sin conexión retrasarán la compactación de forma segura. Se conservan el contenido actual, el acceso y la continuidad de la edición.';

  @override
  String get cloudSharedResend => 'Reenviar invitación';

  @override
  String get cloudSharedQueued => 'Actualización en cola';

  @override
  String get cloudRichTitle => 'Nota compartida';

  @override
  String get cloudRichCollaborative => 'Edición colaborativa cifrada';

  @override
  String get cloudRichReadOnly => 'Acceso de solo lectura';

  @override
  String get cloudRichManage => 'Miembros y acceso';

  @override
  String get cloudRichSave => 'Save';

  @override
  String get cloudRichSaved => 'Nota compartida guardada y en cola';

  @override
  String get cloudRichFailed => 'No se pudo actualizar la nota compartida';

  @override
  String get cloudRichHint => 'Escribid juntos…';

  @override
  String get cloudRichRemotePending =>
      'Llegó un cambio remoto mientras editabas. Al guardar se conservan ambos cambios.';

  @override
  String get cloudRichRecovered =>
      'Una edición sin conexión sobrevivió a un borrado simultáneo y se ha recuperado aquí.';

  @override
  String get cloudRichInvalid =>
      'Una edición autenticada pero no válida se mantuvo inerte.';

  @override
  String get cloudRichDelete => 'Eliminar la versión visible';

  @override
  String get cloudRichDeleteTitle => '¿Eliminar la versión visible aquí?';

  @override
  String get cloudRichDeleteBody =>
      'Este borrado cubre solo los cambios ya visibles en este dispositivo. Una edición simultánea sin conexión se conserva y reaparecerá para revisión en lugar de perderse.';

  @override
  String get cloudRichDeleted =>
      'Versión visible eliminada; las ediciones simultáneas siguen siendo recuperables';

  @override
  String get cloudRichBold => 'Bold';

  @override
  String get cloudRichItalic => 'Italic';

  @override
  String get cloudRichUnderline => 'Underline';

  @override
  String get cloudRichStrike => 'Strikethrough';

  @override
  String get cloudRichCode => 'Código en línea';

  @override
  String get cloudRichParagraph => 'Paragraph';

  @override
  String get cloudRichHeading1 => 'Heading 1';

  @override
  String get cloudRichHeading2 => 'Heading 2';

  @override
  String get cloudRichQuote => 'Quote';

  @override
  String get cloudRichBullet => 'Bullet';

  @override
  String get cloudRichCodeBlock => 'Bloque de código';

  @override
  String get cloudSharedPickKind => 'Tipo de documento compartido';

  @override
  String get cloudKindNote => 'Note';

  @override
  String get cloudKindTasks => 'Lista de tareas';

  @override
  String get cloudKindCalendar => 'Calendar';

  @override
  String get cloudKindFiles => 'Carpeta compartida';

  @override
  String get cloudTasksTitle => 'Tareas compartidas';

  @override
  String get cloudCalendarTitle => 'Calendario compartido';

  @override
  String get cloudCollectionCollaborative => 'Colección colaborativa cifrada';

  @override
  String get cloudCollectionEmptyTasks => 'Todavía no hay tareas';

  @override
  String get cloudCollectionEmptyEvents => 'Todavía no hay eventos';

  @override
  String get cloudTaskAdd => 'Añadir tarea';

  @override
  String get cloudTaskEdit => 'Editar tarea';

  @override
  String get cloudTaskTitle => 'Task';

  @override
  String get cloudTaskNotes => 'Notes';

  @override
  String get cloudTaskDue => 'Fecha límite';

  @override
  String get cloudTaskNoDue => 'Sin fecha límite';

  @override
  String get cloudEventAdd => 'Añadir evento';

  @override
  String get cloudEventEdit => 'Editar evento';

  @override
  String get cloudEventTitle => 'Event';

  @override
  String get cloudEventStart => 'Starts';

  @override
  String get cloudEventEnd => 'Ends';

  @override
  String get cloudEventAllDay => 'Todo el día';

  @override
  String get cloudEventLocation => 'Location';

  @override
  String get cloudCollectionDelete => 'Delete';

  @override
  String cloudCollectionDeleteTitle(String title) {
    return 'Delete \"$title\"?';
  }

  @override
  String get cloudCollectionSaved => 'Cambio guardado y en cola';

  @override
  String get cloudCollectionFailed =>
      'No se pudo actualizar esta colección compartida';

  @override
  String get cloudCollectionInvalidRange =>
      'El evento debe terminar después de empezar';

  @override
  String get cloudCollectionInvalid =>
      'Un cambio autenticado pero no válido se mantuvo inerte.';

  @override
  String get spaceRulesTitle => 'Normas de la comunidad';

  @override
  String get spaceRulesEmpty =>
      'Esta comunidad todavía no ha publicado normas.';

  @override
  String get spaceRulesPublish => 'Publicar normas';

  @override
  String spaceRulesPublishVersion(int version) {
    return 'Publicar la versión $version de las normas';
  }

  @override
  String get spaceRulesFullText => 'Normas completas';

  @override
  String get spaceRulesSummary => 'Resumen breve';

  @override
  String get spaceRulesEffectiveDate => 'Fecha de entrada en vigor';

  @override
  String spaceRulesEffective(String date) {
    return 'Effective $date';
  }

  @override
  String spaceRulesVersion(int version) {
    return 'Version $version';
  }

  @override
  String get spaceRulesAccept => 'Aceptar las normas';

  @override
  String get spaceRulesAccepted => 'Normas aceptadas';

  @override
  String get spaceRulesAcceptanceRequired =>
      'Revisa y acepta las normas vigentes';

  @override
  String get spaceRulesHistory => 'Versiones anteriores';

  @override
  String get spaceModerationTitle => 'Moderation';

  @override
  String get spaceModerationEmpty =>
      'No se ha registrado ninguna acción de moderación.';

  @override
  String get spaceModerationAdd => 'Nueva acción de moderación';

  @override
  String get spaceModerationTarget => 'Member';

  @override
  String get spaceModerationAction => 'Action';

  @override
  String get spaceModerationReason => 'Reason';

  @override
  String get spaceModerationDuration => 'Duration';

  @override
  String get spaceModerationNoExpiry => 'Hasta que se revoque';

  @override
  String get spaceModerationOneHour => '1 hour';

  @override
  String get spaceModerationOneDay => '24 hours';

  @override
  String get spaceModerationOneWeek => '7 days';

  @override
  String get spaceModerationActive => 'Active';

  @override
  String get spaceModerationExpired => 'Expired';

  @override
  String get spaceModerationRevoked => 'Revoked';

  @override
  String get spaceModerationRevoke => 'Revocar la acción';

  @override
  String get spaceModerationRevokeReason => 'Motivo de la revocación';

  @override
  String get spaceModerationWarning => 'Warning';

  @override
  String get spaceModerationDeleteMessage => 'Eliminar el mensaje';

  @override
  String get spaceModerationDeletePost => 'Eliminar la publicación';

  @override
  String get spaceModerationRestrictPublishing =>
      'Restringir temporalmente las publicaciones';

  @override
  String get spaceModerationRestrictMessages => 'Impedir el envío de mensajes';

  @override
  String get spaceModerationRestrictVoice =>
      'Impedir la entrada a los canales de voz';

  @override
  String get spaceModerationMute => 'Silenciar mensajes y voz';

  @override
  String get spaceModerationTimeout => 'Timeout';

  @override
  String get spaceModerationTemporaryBan => 'Expulsión temporal';

  @override
  String get spaceModerationPermanentBan => 'Expulsión permanente';

  @override
  String spaceModerationUntil(String date) {
    return 'Until $date';
  }

  @override
  String get spaceModerationAppealsTitle => 'Apelaciones de moderación';

  @override
  String get spaceModerationAppealAction => 'Appeal';

  @override
  String get spaceModerationAppealDialogTitle =>
      'Apelar la acción de moderación';

  @override
  String get spaceModerationAppealText =>
      'Explica por qué debería revisarse esta acción';

  @override
  String get spaceModerationAppealSent => 'Apelación enviada';

  @override
  String get spaceModerationAppealPending => 'Pendiente de revisión';

  @override
  String get spaceModerationAppealRejected => 'Apelación rechazada';

  @override
  String get spaceModerationAppealRevoked => 'Acción revocada tras la revisión';

  @override
  String get spaceModerationAppealAcknowledged =>
      'Apelación aceptada; el contenido eliminado no se puede restaurar';

  @override
  String spaceModerationAppealFrom(String node) {
    return 'Apelación de $node';
  }

  @override
  String get spaceModerationAppealReview => 'Revisar la apelación';

  @override
  String get spaceModerationAppealDecisionReason =>
      'Explicación de la decisión';

  @override
  String get spaceModerationAppealDecisionReject => 'Mantener la acción';

  @override
  String get spaceModerationAppealDecisionRevoke => 'Revocar la acción';

  @override
  String get spaceModerationAppealDecisionAcknowledge =>
      'Aceptar sin restaurar';

  @override
  String get spaceAbuseReportAction => 'Report';

  @override
  String get spaceAbuseReportDialogTitle => 'Report a violation';

  @override
  String get spaceAbuseReportCategory => 'Motivo de la denuncia';

  @override
  String get spaceAbuseReportCategorySpam => 'Spam o fraude';

  @override
  String get spaceAbuseReportCategoryHarassment => 'Acoso o abuso';

  @override
  String get spaceAbuseReportCategoryViolence => 'Violencia o amenazas';

  @override
  String get spaceAbuseReportCategorySexualContent => 'Contenido sexual';

  @override
  String get spaceAbuseReportCategoryIllegalContent => 'Contenido ilegal';

  @override
  String get spaceAbuseReportCategoryMisinformation => 'Desinformación dañina';

  @override
  String get spaceAbuseReportCategoryOther => 'Other';

  @override
  String get spaceAbuseReportDetails => 'Details (optional)';

  @override
  String get spaceAbuseReportDetailsRequired => 'Añade detalles si eliges Otro';

  @override
  String get spaceAbuseReportSent => 'Denuncia enviada a los moderadores';

  @override
  String get spaceAbuseReportsTitle => 'Reports';

  @override
  String spaceAbuseReportFrom(String node) {
    return 'Denuncia de $node';
  }

  @override
  String get spaceAbuseReportPost => 'Publication';

  @override
  String get spaceAbuseReportComment => 'Comment';

  @override
  String get spaceAbuseReportOpenContent => 'Abrir el contenido';

  @override
  String get spaceAbuseReportReview => 'Revisar la denuncia';

  @override
  String get spaceAbuseReportDecisionReason => 'Explicación de la decisión';

  @override
  String get spaceAbuseReportDecisionDismiss => 'Desestimar la denuncia';

  @override
  String get spaceAbuseReportDecisionResolve => 'Marcar como resuelta';

  @override
  String get spaceAbuseReportDecisionRemove => 'Eliminar el contenido';

  @override
  String get spaceAbuseReportPending => 'Pendiente de revisión';

  @override
  String get spaceAbuseReportDismissed => 'No se encontró ninguna infracción';

  @override
  String get spaceAbuseReportResolved => 'Resolved';

  @override
  String get spaceAbuseReportRemoved => 'Contenido eliminado';

  @override
  String get profileTitle => 'Profiles';

  @override
  String get profileSettingsHint =>
      'Ejecuta una instalación aparte desde su propio contenedor';

  @override
  String get profileExplainer =>
      'Un perfil es una instalación aparte: su propio contenedor, su propia contraseña, sus propias identidades. No se comparte nada entre perfiles. Úsalo para mantener una versión de prueba lejos de tus datos reales.';

  @override
  String get profileDefaultName => 'Default (production)';

  @override
  String get profileRunningNow => 'En ejecución ahora';

  @override
  String get profileChoiceNotSaved =>
      'No se pudo guardar la elección: el próximo inicio usará el perfil actual';

  @override
  String get profileRestartRequired => 'Reinicia xVeil para cambiar de perfil';

  @override
  String get profileSwitchNote =>
      'El perfil elegido se recuerda y se aplica en el próximo inicio. En escritorio también puedes pasar --profile <nombre>; en el móvil, define XVEIL_PROFILE antes de iniciar.';

  @override
  String get profileCreateTitle => 'Nuevo perfil';

  @override
  String get profileNameHint => 'por ejemplo: pruebas';

  @override
  String get profileNameRule =>
      'Minúsculas, dígitos, punto, guion y guion bajo. Hasta 32 caracteres.';

  @override
  String get profileRevealed => 'Perfiles desbloqueados';

  @override
  String get commonCreate => 'Create';

  @override
  String get folderSyncTitle => 'Sincronización de carpetas';

  @override
  String get folderSyncHint =>
      'Refleja una carpeta de este equipo en una carpeta de Almacenamiento';

  @override
  String get folderSyncEmpty =>
      'Todavía no se está reflejando ninguna carpeta.';

  @override
  String get folderSyncAdd => 'Add a folder';

  @override
  String get folderSyncRunNow => 'Sincronizar ahora';

  @override
  String get folderSyncRemove => 'Dejar de reflejar';

  @override
  String get folderSyncNever => 'Aún sin sincronizar';

  @override
  String folderSyncRefused(String reason) {
    return 'Stopped: $reason';
  }

  @override
  String get folderSyncConflictsTitle => 'Necesita tu decisión';

  @override
  String get folderSyncConflictExplain =>
      'Este archivo cambió aquí y en Almacenamiento a la vez. No se sobrescribió nada. Elige qué copia conservar y vuelve a sincronizar.';

  @override
  String get folderSyncKeepLocal => 'Conservar la de este equipo';

  @override
  String get folderSyncKeepCloud => 'Conservar la de Almacenamiento';

  @override
  String get folderSyncCloudRoot => 'Raíz de Almacenamiento';

  @override
  String get folderSyncBusy => 'Syncing…';

  @override
  String get folderSyncDeleteWarning =>
      'Si borras un archivo aquí, también se borra en Almacenamiento.';

  @override
  String get folderSyncNotAddedTitle => 'No se ha añadido la carpeta';

  @override
  String folderSyncNotAdded(String reason) {
    return '$reason. No se ha copiado nada ni ha cambiado nada en este equipo. Elige otra carpeta: una dentro de tu carpeta personal, en la que solo pueda escribir tu propia cuenta.';
  }

  @override
  String get folderSyncRefusedOverlap =>
      'se solapa con una carpeta que ya se está sincronizando';

  @override
  String folderSyncRefusedUnresolvable(String path, String detail) {
    return 'no se ha podido determinar la ubicación real de $path ($detail)';
  }

  @override
  String folderSyncRefusedUnreadable(String path) {
    return 'no se han podido leer los permisos de $path';
  }

  @override
  String folderSyncRefusedWritable(String path) {
    return 'otras cuentas de este equipo pueden escribir en $path, así que lo que se copie ahí podría redirigirse a otro sitio';
  }

  @override
  String get settingsCopyErrors => 'Copiar informe de errores';

  @override
  String get settingsCopyErrorsHint =>
      'Un resumen JSON de los fallos recientes: solo tipos de error y ubicaciones en el código, sin texto de error, contactos ni identidad.';

  @override
  String settingsCopyErrorsDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count fallos',
      one: '1 fallo',
      zero: 'sin fallos registrados',
    );
    return 'Informe de errores copiado ($_temp0)';
  }

  @override
  String get errorLoadFailed => 'No se pudo cargar esto';

  @override
  String get errorLoadFailedHint =>
      'Los detalles están en Ajustes → Copiar informe de errores.';

  @override
  String get voiceModelDownload => 'Descargar el modelo de voz';

  @override
  String get voiceModelSize => '57 MB, una vez para toda la aplicación';

  @override
  String get voiceModelDownloading => 'Descargando el modelo de voz…';

  @override
  String get voiceModelFailed => 'Fallo en la descarga: toca para reintentar';

  @override
  String get voiceModelInstalled => 'Modelo de voz instalado';

  @override
  String get voiceModelRemove => 'Quitar el modelo de voz';

  @override
  String get voiceModelRemoveHint =>
      'Libera 57 MB. La transcripción deja de funcionar hasta que vuelvas a descargarlo.';

  @override
  String get modelBundleTranslate => 'Modelo de traducción';

  @override
  String get modelBundleSpeech => 'Modelo de voz';

  @override
  String get modelBundleDownload => 'Descargar';

  @override
  String get modelBundleInstall => 'Instalar';

  @override
  String get modelBundleInstalling => 'Instalando…';

  @override
  String get modelBundleInstalled => 'Instalado';

  @override
  String get modelBundleFailed => 'No se pudo instalar';

  @override
  String get modelBundleMissing => 'el archivo no está en este dispositivo';

  @override
  String get modelBundleTrust =>
      'Un modelo decide lo que esta aplicación dice que otros escribieron. Instálalo solo de alguien en quien confíes.';

  @override
  String get voiceModelImport => 'Instalar desde un archivo…';

  @override
  String get voiceModelImportHint =>
      'Un archivo .veilaudio, si alguien ya lo descargó';

  @override
  String get translationModels => 'Idiomas de traducción';

  @override
  String get translationModelsNone => 'No hay idiomas instalados';

  @override
  String get translationModelsImport => 'Instalar desde un archivo…';

  @override
  String get translationModelsImporting => 'Instalando…';

  @override
  String get translationModelsFailed => 'No se pudo instalar este archivo';

  @override
  String get translationModelsRemove => 'Eliminar este idioma';

  @override
  String get translationModelsShare => 'Guardar como archivo para enviar';

  @override
  String get translationModelsHint =>
      'Un archivo .veiltranslate por dirección. La traducción ocurre en este dispositivo.';

  @override
  String get voiceModelResume => 'Continuar la descarga';

  @override
  String voiceModelResumeAt(int percent) {
    return '$percent % ya descargado';
  }

  @override
  String get voiceModelCancel => 'Stop';

  @override
  String get identityDamagedTitle =>
      'Este espacio se abrió, pero su identidad está dañada';

  @override
  String get identityDamagedBody =>
      'Tu contraseña era correcta: el contenedor se desbloqueó. Lo que hay donde debería estar tu identidad no se puede leer. Esta aplicación no continuará actuando como si fueras alguien nuevo.';

  @override
  String get identityDamagedUntouched =>
      'No se cambió ni se sobrescribió nada. Tus datos siguen en el contenedor exactamente como se encontraron.';

  @override
  String get identityDamagedBack => 'Volver a la pantalla de bloqueo';

  @override
  String get backupNotExcludedTitle =>
      'Este dispositivo podría estar copiando tus datos en su copia de seguridad';

  @override
  String backupNotExcludedBody(String reason) {
    return 'xVeil pide al sistema que mantenga su contenedor fuera de iCloud y de las copias de seguridad del equipo. En este dispositivo eso no surtió efecto ($reason). Tus datos siguen cifrados, pero una copia de seguridad podría revelar que esta aplicación guarda una identidad, y esa copia podría atacarse lejos de tu teléfono. Desactivar la copia de seguridad de xVeil en los ajustes del sistema lo evita.';
  }

  @override
  String devicesLastSeen(String when) {
    return 'Visto por última vez $when';
  }

  @override
  String get devicesNeverSeen =>
      'Nunca visto desde que se vinculó este dispositivo';

  @override
  String get devicesAwayLong =>
      'Lleva mucho tiempo ausente: conviene desvincularlo';

  @override
  String get callNotificationIncoming => 'Llamada xVeil entrante';

  @override
  String get callNotificationDialing => 'Llamando con xVeil';

  @override
  String get callNotificationActive => 'Llamada xVeil en curso';

  @override
  String get callNotificationGroupIncoming => 'Llamada grupal xVeil entrante';

  @override
  String get callNotificationGroup => 'Llamada grupal xVeil';

  @override
  String get chatListWantsToConnect => 'quiere conectar';

  @override
  String get chatListRequestSent => 'solicitud enviada';

  @override
  String get chatListBlocked => 'bloqueado';

  @override
  String get agoJustNow => 'ahora mismo';

  @override
  String agoMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count minutos',
      one: 'hace 1 minuto',
    );
    return '$_temp0';
  }

  @override
  String agoHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count horas',
      one: 'hace 1 hora',
    );
    return '$_temp0';
  }

  @override
  String agoDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count días',
      one: 'hace 1 día',
    );
    return '$_temp0';
  }

  @override
  String agoMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count meses',
      one: 'hace 1 mes',
    );
    return '$_temp0';
  }

  @override
  String agoYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'hace $count años',
      one: 'hace 1 año',
    );
    return '$_temp0';
  }

  @override
  String folderSyncLastPass(String when) {
    return 'Sincronizado $when';
  }

  @override
  String get inviteAcceptsHint => 'Un enlace de invitación o @nombre';

  @override
  String get chatTranslate => 'Traducir';

  @override
  String get chatTranslating => 'Traduciendo…';

  @override
  String get chatTranslateFailed => 'No se pudo traducir: toca para reintentar';

  @override
  String get chatTranslationShowOriginal => 'Mostrar el original';

  @override
  String get chatTranslateInto => 'Traducir a…';

  @override
  String get modelProvenanceTitleMismatch =>
      'Este modelo no coincide con el publicado';

  @override
  String get modelProvenanceTitleUnknown => 'Este modelo no se puede comprobar';

  @override
  String modelProvenanceBodyMismatch(String files) {
    return 'El hash de $files difiere del incluido en esta aplicación. O la copia de tu contacto no es el modelo publicado, o fue alterada. Un modelo es la entrada del motor que lee tu micrófono y tus mensajes.';
  }

  @override
  String get modelProvenanceBodyUnknown =>
      'Esta compilación no tiene un hash de referencia para este modelo, así que no hay con qué compararlo. No es una acusación: significa que aquí no se puede hacer la comprobación.';

  @override
  String get modelProvenanceInstallAnyway => 'Instalar de todos modos';

  @override
  String get modelProvenanceLoadManually => 'Buscarlo y cargarlo yo mismo';

  @override
  String get modelProvenanceRisk => 'Bajo tu propia responsabilidad.';

  @override
  String get modelSharingTitle => 'Responder a los contactos que piden modelos';

  @override
  String get modelSharingOn =>
      'Tus contactos ven qué modelos de idioma y de voz tienes, y pueden pedir una copia.';

  @override
  String get modelSharingOff =>
      'Tus contactos no reciben respuesta. No pueden distinguirlo de que no tengas modelos.';

  @override
  String get askContactsTitle => 'Pedir modelos a los contactos';

  @override
  String get askContactsWaiting =>
      'Quien responda aparecerá aquí. El silencio no significa nada en concreto.';

  @override
  String get askContactsAction => 'Preguntar a mis contactos';

  @override
  String get modelProvenanceAskAnother => 'Preguntar a otro contacto';

  @override
  String settingsApiTokenCopiedClears(int seconds) {
    return 'Token copiado. El portapapeles se borrará en $seconds segundos.';
  }

  @override
  String get seedsChoiceTitle => 'Cómo encuentra la red este dispositivo';

  @override
  String get seedsChoiceBody =>
      'xVeil no tiene servidor central, así que un dispositivo nuevo necesita al menos un nodo al que llegar antes de que pueda ocurrir nada más. Elige cómo consigue el primero esta identidad.';

  @override
  String get seedsUseTitle =>
      'Usar los nodos de entrada compartidos (recomendado)';

  @override
  String get seedsUseBody =>
      'La aplicación se conecta sola, sin que tengas que configurar nada. Esos nodos los mantiene el proyecto, y se enteran de que existe un nodo tuyo y desde qué dirección se conecta; no de quién eres ni de lo que envías.';

  @override
  String get seedsDeclineTitle => 'Solo los nodos que añada yo';

  @override
  String get seedsDeclineBody =>
      'Para esta identidad no se contacta con ningún nodo compartido, así que el servidor de nadie más sabrá que existe. Tus otras identidades no se ven afectadas. Nada funciona hasta que añadas un nodo tú: no se podrán enviar mensajes ni llegará ninguno.';

  @override
  String get seedsChoiceChangeLater =>
      'Puedes cambiarlo más adelante en los ajustes de red.';

  @override
  String get seedsReofferTitle => 'Esta identidad no puede llegar a la red';

  @override
  String get seedsReofferBody =>
      'Elegiste usar solo nodos añadidos por ti, y no has añadido ninguno. Mientras no lo hagas, no se puede enviar ni recibir ningún mensaje. Puedes añadir tu nodo ahora o usar después de todo los nodos de entrada compartidos: se enteran de que existe un nodo tuyo y desde qué dirección se conecta. Elijas lo que elijas, la respuesta se guarda solo para esta identidad.';

  @override
  String get seedsReofferUse => 'Usar los nodos compartidos';

  @override
  String get seedsReofferKeep => 'Mantener mi elección';

  @override
  String get seedsReofferDontAsk => 'No volver a mostrar';

  @override
  String get seedsNoNodeTitle => 'Todavía no hay forma de llegar a la red';

  @override
  String get seedsNoNodeBody =>
      'Esta identidad no usa los nodos de entrada compartidos, así que necesita uno tuyo. Añádelo y la aplicación se conectará.';

  @override
  String get seedsNoNodeAction => 'Añadir mi nodo';

  @override
  String get seedsRestartToApply =>
      'Los nodos compartidos se han guardado para esta identidad, pero no se pudo reiniciar el nodo en ejecución. Cierra la aplicación y vuelve a abrirla para conectarte.';

  @override
  String get seedsSaveFailed =>
      'No se pudo guardar esa elección. Solo se aplica a esta sesión.';

  @override
  String get dhtServeTitle => 'Servir a la red';

  @override
  String get dhtServeOnSub =>
      'Este dispositivo guarda registros de otras personas y transporta sus búsquedas. Medido en un cliente inactivo: cerca del 85% de todo lo recibido. Mantiene los datos de la red repartidos entre muchas máquinas.';

  @override
  String get dhtServeOffSub =>
      'Se pide a los pares que no elijan este dispositivo para su almacenamiento ni sus búsquedas. Tus mensajes, contactos y entregas no se ven afectados. Menos máquinas guardan entonces los datos de la red.';

  @override
  String get dhtServeSaveFailed => 'No se pudo guardar el ajuste';

  @override
  String get seedsSwitchTitle => 'Usar los nodos de entrada compartidos';

  @override
  String get seedsSwitchOnSub =>
      'Activado para esta identidad: la aplicación encuentra la red por su cuenta. Los nodos del proyecto se enteran de que existe un nodo tuyo y desde qué dirección se conecta.';

  @override
  String get seedsSwitchOffSub =>
      'Desactivado para esta identidad: solo los nodos que añadas tú. No habrá conexión hasta que añadas uno. Tus otras identidades no se ven afectadas.';

  @override
  String get seedsSwitchSaveFailed =>
      'No se pudo guardar el cambio, así que no se ha aplicado.';

  @override
  String get devicesResendSetup => 'Enviar de nuevo la configuración cifrada';

  @override
  String get devicesResendHint =>
      'Para un dispositivo ya vinculado que nunca la recibió';

  @override
  String get devicesSendUnreachable =>
      'El otro dispositivo no respondió. Abre xVeil allí, espera a que se conecte e inténtalo de nuevo.';

  @override
  String get devicesSendNoTargets =>
      'Todavía no hay ningún dispositivo vinculado al que enviar';

  @override
  String get networkBackgroundOfferBody =>
      'Sin esto Android detiene xVeil en cuanto se apaga la pantalla: el nodo se para, dejan de llegar mensajes y la aplicación sigue pareciendo correcta. Algunos teléfonos (Xiaomi, Samsung) esconden además un “Inicio automático” en los ajustes de la propia aplicación que también debe estar activado.\n\nPuedes activarlo más tarde en cualquier momento: Ajustes → Red overlay → Funcionar en segundo plano.';

  @override
  String get networkBackgroundNeverAsk => 'No volver a preguntar';
}
