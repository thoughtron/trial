#|
 This file is a part of trial
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

;; FIXME: configurable defaults

(in-package #:org.shirakumo.fraf.trial)
(in-readtable :qtools)

(defclass context-asset (asset)
  ((resource :initform (tg:make-weak-hash-table :weakness :key-and-value))))

(defmethod resource ((asset context-asset))
  (when *context*
    (gethash *context* (slot-value asset 'resource))))

(defmethod (setf resource) (value (asset context-asset))
  (unless *context*
    (error "Cannot update resource of ~a without an active context!" asset))
  (if value
      (setf (gethash *context* (slot-value asset 'resource)) value)
      (remhash value (slot-value asset 'resource))))

(defun call-with-asset-context (asset func)
  (if *context*
      (funcall func)
      (loop for context being the hash-keys of (slot-value asset 'resource)
            do (when (and context (qobject-alive-p context) (q+:is-valid context))
                 (with-context (context)
                   (funcall func))))))

(defmethod reload :around ((asset context-asset))
  (call-with-asset-context asset #'call-next-method))

(defmethod load-data :around ((asset context-asset))
  (call-with-asset-context asset #'call-next-method))

(defmethod finalize-data :around ((asset context-asset) data)
  (call-with-asset-context asset #'call-next-method))

(defclass file-asset (asset)
  ((file :initform NIL :accessor file))
  (:default-initargs
   :file (error "FILE required.")))

(defmethod shared-initialize :after ((asset file-asset) slot-names &key (file (file asset)))
  (setf (file asset) file)
  (unless (probe-file (file asset))
    (emit-compilation-note "Defining asset ~a on inexistent file: ~a"
                           asset (file asset))))

(defmethod (setf file) (thing (asset file-asset))
  (error "Cannot set ~s as file on ~a. Must be a pathname-designator."
         thing asset))

(defmethod (setf file) ((file string) (asset file-asset))
  (setf (file asset) (uiop:parse-native-namestring file)))

(defmethod (setf file) ((file pathname) (asset file-asset))
  ;; FIXME: How to notify pool of change?
  (setf (slot-value asset 'file) (pathname-utils:normalize-pathname file)))

(defmethod (setf file) :after ((file pathname) (asset file-asset))
  (reload asset))

(defmethod file ((asset file-asset))
  (merge-pathnames (slot-value asset 'file) (base (home asset))))

(defmethod load-data :before ((asset file-asset))
  (unless (probe-file (file asset))
    (error "File for asset ~a not found on disk: ~a"
           asset (file asset))))

(defmethod load-data :around ((asset file-asset))
  (with-new-value-restart ((file asset)) (use-file "Enter a new file to use.")
    (call-next-method)))

(defclass image (file-asset)
  ())

(defmethod load-data ((asset image))
  (let ((image (q+:make-qimage (uiop:native-namestring (file asset)))))
    (when (q+:is-null image)
      (finalize image)
      (error "Qt failed to load image for ~a" asset))
    image))

(defmethod finalize-data ((asset image) data)
  (finalize data))

(defvar *global-font-cache* (make-hash-table :test 'equal))

(defun global-font (family)
  (or (gethash family *global-font-cache*)
      (setf (gethash family *global-font-cache*)
            (q+:make-qfont family))))

(defclass font (context-asset)
  ((size :initarg :size :accessor size)
   (family :initarg :family :accessor family))
  (:default-initargs
   :size 12
   :family (error "FAMILY required.")))

(defmethod (setf family) :after (family (asset font))
  (reload asset))

(defmethod (setf size) :after (size (asset font))
  (reload asset))

(defmethod load-data ((asset font))
  (let ((font (q+:make-qfont (global-font (family asset)) *context*)))
    (setf (q+:point-size font) (size asset))
    font))

(defmethod finalize-data ((asset font) data)
  (finalize data))

(defclass texture (image context-asset)
  ((target :initarg :target :reader target)
   (mag-filter :initarg :mag-filter :reader mag-filter)
   (min-filter :initarg :min-filter :reader min-filter)
   (anisotropy :initarg :anisotropy :reader anisotropy)
   (wrapping :initarg :wrapping :reader wrapping))
  (:default-initargs
   :target :texture-2d
   :mag-filter :linear
   :min-filter :linear
   :anisotropy NIL
   :wrapping :clamp-to-edge))

(defmethod shared-initialize :before ((asset texture) slot-names &key (target (target asset))
                                                                      (mag-filter (mag-filter asset))
                                                                      (min-filter (min-filter asset)))
  (check-texture-target target)
  (check-texture-mag-filter mag-filter)
  (check-texture-min-filter min-filter))

(defun image-buffer-to-texture (buffer target)
  (ecase target
    (:texture-2d
     (gl:tex-image-2d target 0 :rgba (q+:width buffer) (q+:height buffer) 0 :rgba :unsigned-byte (q+:bits buffer)))
    (:texture-cube-map
     (loop with width = (q+:width buffer)
           with height = (/ (q+:height buffer) 6)
           for target in '(:texture-cube-map-positive-x :texture-cube-map-negative-x
                           :texture-cube-map-positive-y :texture-cube-map-negative-y
                           :texture-cube-map-positive-z :texture-cube-map-negative-z)
           for index from 0
           do (gl:tex-image-2d target 0 :rgba width height 0 :rgba :unsigned-byte
                               (cffi:inc-pointer (q+:bits buffer) (* width height index 4)))))))

(defmethod load-data ((asset texture))
  (with-slots (target mag-filter min-filter anisotropy wrapping) asset
    (let ((image (call-next-method)))
      (check-texture-size (q+:width image) (q+:height image))
      (with-finalizing ((buffer (q+:qglwidget-convert-to-glformat image)))
        (finalize image)
        (let ((texture (gl:gen-texture)))
          (gl:bind-texture target texture)
          (with-cleanup-on-failure
              (finalize-data asset texture)
            (image-buffer-to-texture buffer target)
            (gl:tex-parameter target :texture-min-filter min-filter)
            (gl:tex-parameter target :texture-mag-filter mag-filter)
            (when anisotropy
              (gl:tex-parameter target :texture-max-anisotropy-ext anisotropy))
            (gl:tex-parameter target :texture-wrap-s wrapping)
            (gl:tex-parameter target :texture-wrap-t wrapping)
            (unless (eql target :texture-2d)
              (gl:tex-parameter target :texture-wrap-r wrapping))
            (gl:bind-texture target 0))
          texture)))))

(defmethod finalize-data ((asset texture) data)
  (gl:delete-textures (list data)))

(defclass model (file-asset)
  ((texture-map :initarg :texture-map :accessor texture-map)
   (texture-store :initform () :accessor texture-store))
  (:default-initargs
   :texture-map ()))

(defmethod load-data ((model model))
  (let ((data (wavefront-loader:load-obj (file model))))
    (loop for obj across data
          for diffuse = (wavefront-loader:diffuse-map (wavefront-loader:material obj))
          do (when diffuse
               (let* ((texture (or (cdr (assoc diffuse (texture-map model) :test #'string-equal))
                                   diffuse))
                      (asset (etypecase texture
                               (string (make-instance 'texture :file texture))
                               (cons (asset 'texture (first texture) (second texture)))))
                      (resource (resource (restore asset))))
                 (pushnew resource (texture-store model))
                 (setf (wavefront-loader:diffuse-map (wavefront-loader:material obj))
                       (data resource)))))))

(defmethod finalize-data :after ((model model) data)
  ;; Free references
  (setf (texture-store model) ()))

;; FIXME: allow specifying inline shaders
(defclass shader (file-asset context-asset)
  ((shader-type :initarg :shader-type :reader shader-type))
  (:default-initargs
   :shader-type NIL))

(defun pathname->shader-type (pathname)
  (or (cdr (assoc (pathname-type pathname)
                  `((glsl . :vertex-shader)
                    (tesc . :tess-control-shader)
                    (tese . :tess-evaluation-shader)
                    (vert . :vertex-shader)
                    (geom . :geometry-shader)
                    (frag . :fragment-shader)
                    (comp . :compute-shader)
                    (tcs . :tess-control-shader)
                    (tes . :tess-evaluation-shader)
                    (vs . :vertex-shader)
                    (gs . :geometry-shader)
                    (fs . :fragment-shader)
                    (cs . :compute-shader)) :test #'string-equal))
      (error "Don't know how to convert ~s to shader type." pathname)))

(defmethod shared-initialize :before ((asset shader) slot-names &key shader-type)
  (when shader-type (check-shader-type shader-type)))

(defmethod shared-initialize :after ((asset shader) slot-names &key)
  (unless (shader-type asset)
    (setf (slot-value asset 'shader-type) (pathname->shader-type (file asset)))))

(defmethod load-data ((asset shader))
  (let ((source (alexandria:read-file-into-string (file asset)))
        (shader (gl:create-shader (shader-type asset))))
    (with-cleanup-on-failure
        (finalize-data asset shader)
      (with-new-value-restart (source input-source) (use-source "Supply new source code directly.")
        (gl:shader-source shader source)
        (gl:compile-shader shader)
        (unless (gl:get-shader shader :compile-status)
          (error "Failed to compile ~a: ~%~a" asset (gl:get-shader-info-log shader)))))
    shader))

(defmethod finalize-data ((asset shader) data)
  (gl:delete-shader data))

(defclass shader-program (context-asset)
  ((shaders :initarg :shaders :accessor shaders)))

(defmethod initialize-instance :after ((asset shader-program) &key shaders)
  ;; Automatically register all shaders as dependencies.
  (dolist (shader shaders)
    (pushnew (list* 'shader shader) (dependencies asset) :test #'equal)))

(defmethod (setf shaders) :after (shaders (asset shader-program))
  (reload asset)
  ;; Remove deps if not found. This is not perfect as we don't know whether the user perhaps
  ;; specifically requested a shader in the dependencies that is not actually included.
  (setf (dependencies asset)
        (remove-if (lambda (dep) (and (eql (first dep) 'shader)
                                      (not (find (rest dep) shaders :test #'equal)))) (dependencies asset))))

(defmethod load-data ((asset shader-program))
  (let ((shaders (loop for (pool name) in (shaders asset)
                       collect (get-resource 'shader pool name)))
        (program (gl:create-program)))
    (with-cleanup-on-failure
        (finalize-data asset program)
      (mapc (lambda (shader) (gl:attach-shader program (data shader))) shaders)
      (gl:link-program program)
      (mapc (lambda (shader) (gl:detach-shader program (data shader))) shaders)
      (unless (gl:get-program program :link-status)
        (error "Failed to link ~a: ~%~a" asset (gl:get-program-info-log program))))
    program))

(defmethod finalize-data ((asset shader-program) data)
  (gl:delete-program data))

;; FIXME: allow loading from file or non-array type
(defclass vertex-buffer (context-asset)
  ((buffer-type :initarg :buffer-type :accessor buffer-type)
   (element-type :initarg :element-type :accessor element-type)
   (buffer-data :initarg :buffer-data :accessor buffer-data)
   (data-usage :initarg :data-usage :accessor data-usage))
  (:default-initargs
   :buffer-type :array-buffer
   :element-type :float
   :data-usage :static-draw))

(defmethod shared-initialize :before ((asset vertex-buffer) slot-names &key (buffer-type (buffer-type asset))
                                                                            (element-type (element-type asset))
                                                                            (data-usage (data-usage asset)))
  ;; FIXME: automatically determine element-type from buffer-data if not specified
  (check-vertex-buffer-type buffer-type)
  (check-vertex-buffer-element-type element-type)
  (check-vertex-buffer-data-usage data-usage))

(defmethod (setf buffer-data) :after (data (asset vertex-buffer))
  (reload asset))

(defmethod load-data ((asset vertex-buffer))
  (with-slots (element-type buffer-data buffer-type data-usage) asset
    (let ((buffer (gl:gen-buffer))
          (array (gl:alloc-gl-array element-type (length buffer-data))))
      (unwind-protect
           (with-cleanup-on-failure
               (finalize-data asset buffer)
             (gl:bind-buffer buffer-type buffer)
             (loop for i from 0
                   for el across buffer-data
                   do (setf (gl:glaref array i) el))
             (gl:buffer-data buffer-type data-usage array))
        (gl:bind-buffer buffer-type 0)
        (gl:free-gl-array array))
      buffer)))

(defmethod finalize-data ((asset vertex-buffer) data)
  (gl:delete-buffers (list data)))

(defclass vertex-array (context-asset)
  ((buffers :initarg :buffers :accessor buffers)))

(defmethod initialize-instance :after ((asset vertex-array) &key buffers)
  ;; Automatically register all buffers as dependencies.
  (dolist (buffer buffers)
    (pushnew (list* 'vertex-buffer buffer) (dependencies asset) :test #'equal)))

(defmethod (setf buffers) :after (buffers (asset vertex-array))
  (reload asset)
  ;; Remove deps if not found. This is not perfect as we don't know whether the user perhaps
  ;; specifically requested a buffer in the dependencies that is not actually included.
  (setf (dependencies asset)
        (remove-if (lambda (dep) (and (eql (first dep) 'vertex-buffer)
                                      (not (find (rest dep) buffers :test #'equal)))) (dependencies asset))))

(defmethod load-data ((asset vertex-array))
  (let ((array (gl:gen-vertex-array)))
    (with-cleanup-on-failure
        (finalize-data asset array)
      (gl:bind-vertex-array array)
      (loop for buffer in (buffers asset)
            do (destructuring-bind (pool name &key (index 0)
                                                   (size 3)
                                                   (normalized NIL)
                                                   (stride 0))
                   buffer
                 (let ((buffer (asset 'vertex-buffer pool name)))
                   (gl:bind-buffer (buffer-type buffer) (data buffer))
                   (gl:enable-vertex-attrib-array index)
                   (gl:vertex-attrib-pointer index size (element-type buffer) normalized stride (cffi:null-pointer))))))
    array))

(defmethod finalize-data ((asset vertex-array) data)
  (gl:delete-vertex-arrays (list data)))

(defclass framebuffer (context-asset)
  ((attachment :initarg :attachment :reader attachment)
   (width :initarg :width :reader width)
   (height :initarg :height :reader height)
   (mipmap :initarg :mipmap :reader mipmap)
   (samples :initarg :samples :reader samples))
  (:default-initargs
   :attachment :depth-stencil
   :mipmap NIL
   :samples 0
   :width (error "WIDTH required.")
   :height (error "HEIGHT required.")))

(defmethod shared-initialize :before ((asset framebuffer) slots &key attachment)
  (check-framebuffer-attachment attachment))

(defun framebuffer-attachment-value (attachment)
  (ecase attachment
    ((:depth-stencil)
     (q+:qglframebufferobject.combined-depth-stencil))
    (:depth
     (q+:qglframebufferobject.depth))
    ((NIL)
     (q+:qglframebufferobject.no-attachment))))

(defmethod load-data ((asset framebuffer))
  (with-finalizing ((format (q+:make-qglframebufferobjectformat)))
    (setf (q+:mipmap format) (mipmap asset))
    (setf (q+:samples format) (samples asset))
    (setf (q+:attachment format) (framebuffer-attachment-value (attachment asset)))
    (q+:make-qglframebufferobject (width asset) (height asset) format)))

(defmethod finalize-data ((asset framebuffer) data)
  (finalize data))
