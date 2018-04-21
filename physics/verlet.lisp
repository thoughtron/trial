#|
This file is a part of trial
(c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
Author: Janne Pakarinen <gingeralesy@gmail.com>
|#

(in-package #:org.shirakumo.fraf.trial.physics)

(defvar *iterations* 5
  "Number of physics calculation iterations. Increases accuracy of calculations.
In general, 4 is minimum for an alright accuracy, 8 is enough for a good accuracy.")


(defclass verlet-point (located-entity) ())
(define-shader-entity verlet-entity (physical-entity vertex-entity) ())


(defclass verlet-point (located-entity)
  ((old-location :initform NIL :accessor old-location)
   (acceleration :initform NIL :accessor acceleration)
   (viscosity :initarg :viscosity :accessor viscosity)
   (mass :initarg :mass :accessor mass))
  (:default-initargs :mass 1.0
                     :viscosity 1.0))

(defmethod initialize-instance :after ((point verlet-point) &key old-location)
  (setf (old-location point) (or old-location (location point))))

(defmethod apply-force ((point verlet-point) force)
  (when force
    (setf (acceleration point) (v+ (or (acceleration point)
                                       (v* (location point) 0.0))
                                   force))))

(defmethod accelerate ((point verlet-point) delta)
  (let ((delta (when (vec-p (acceleration point))
                 (acceleration point))))
    (when delta (nv+ (location point) delta)))
  (setf (acceleration point) (v* (location point) 0.0)))

(defmethod inertia ((point verlet-point) delta)
  (let ((loc (v- (v* (location point) 2.0) (old-location point))))
    (setf (old-location point) (location point)
          (location point) loc)))

(define-shader-entity verlet-entity (physical-entity vertex-entity)
  ((mass-points :initform NIL :accessor mass-points)
   (constraints :initform NIL :accessor constraints)
   (center :initform NIL :accessor center)
   (viscosity :initarg :viscosity :reader viscosity))
  (:default-initargs :viscosity 1.0))

(defmethod initialize-instance :after ((entity verlet-entity) &key mass-points vertex-array location)
  (let* ((point-array (or mass-points vertex-array))
         (mass-points (etypecase point-array
                        (mesh (vertices (input vertex-array)))
                        (vertex-mesh (mass-points point-array))
                        ((or list array) point-array))))
    (unless (< 3 (length mass-points))
      (error "MASS-POINTS or VERTEX-ARRAY required"))
    (let ((mass-points (quick-hull mass-points)))
      (setf (mass-points entity) (mapcar #'(lambda (loc)
                                             (make-instance 'verlet-point
                                                            :location (v+ location loc)
                                                            :viscosity (viscosity entity)))
                                         mass-points))
      (setf (constraints entity) (loop with first = (first (mass-points entity))
                                       for points = (mass-points entity) then (rest points)
                                       while points
                                       for current = (first points)
                                       for next = (or (second points) first)
                                       collect (make-instance 'distance-constraint :point-a current
                                                                                   :point-b next))))
    (let ((center (make-instance 'verlet-point :location location)))
      (push (make-instance 'distance-constraint :point-a center
                                                :point-b (first (mass-points entity)))
            (constraints entity))
      (push (make-instance 'distance-constraint :point-a center
                                                :point-b (second (mass-points entity)))
            (constraints entity))
      (push (make-instance 'distance-constraint :point-a center
                                                :point-b (third (mass-points entity)))
            (constraints entity))
      (push center (mass-points entity))
      (setf (center entity) center))))

(defmethod location :around ((entity verlet-entity))
  (let ((center (location (center entity))))
    (unless (v= center (call-next-method))
      (setf (slot-value entity 'location) center))
    center))

(defmethod (setf location) (value (entity verlet-entity))
  (declare (type vec value))
  (let ((diff (v- value (location (center entity)))))
    (for:for ((point in (mass-points entity)))
      (nv+ (location point) diff)))
  (call-next-method))

(defmethod (setf viscosity) (value (entity verlet-entity))
  (declare (type number value))
  (setf (slot-value entity 'viscosity) value)
  (for:for ((point in (mass-points entity)))
    (setf (viscosity point) value)))

(defmethod constrain ((entity verlet-entity) type &rest args)
  (let* ((type (ensure-constraint type))
         (args (if (or (eql type 'distance-constraint)
                       (eql type 'angle-constraint)
                       (getf args :point))
                   args
                   (append args (list :point (center entity))))))
    (push (apply #'make-instance type args) (constraints entity))))


(defun verlet-simulation (entities delta &key forces (iterations *iterations*))
  ;; Simulations
  (let ((collidables ()))
    (let ((delta (/ (coerce delta 'single-float) iterations))
          (half-delta (/ delta 2))
          (forces
            (let ((forces (if (vec-p forces) (list forces) forces)))
              (for:for ((entity in entities)
                        (static-forces = (static-forces entity))
                        (all-forces = (when (or forces static-forces)
                                        (apply #'v+ (append forces
                                                            (if (vec-p static-forces)
                                                                (list static-forces)
                                                                static-forces)))))
                        (force-list collecting all-forces))
                (when (typep entity 'collidable-entity)
                  (push entity collidables))
                (returning force-list)))))
      (dotimes (i iterations)
        ;; Apply forces
        (for:for ((entity in entities)
                  (force in forces)
                  (center = (center entity)))
          (apply-force center force)
          (accelerate center delta))
        ;; Collision checks without preserving impulse
        (loop for entity-list = collidables then (rest entity-list)
              while (rest entity-list)
              for entity = (first entity-list)
              do (for:for ((other in (rest entity-list)))
                   (let ((data (collides-p entity other)))
                     (when data (resolve entity other :data data)))))
        ;; Check constraints
        (for:for ((entity in entities))
          (for:for ((constraint in (constraints entity)))
            (when (typep constraint 'frame-constraint))
            (relax constraint half-delta)))
        ;; Handle inertia based on old location
        (for:for ((entity in entities))
          (inertia (center entity) delta))
        ;; TODO: collision checks with preserving impulse here
        ;; Finalise constraints with impulse preservation
        (for:for ((entity in entities))
          (for:for ((constraint in (constraints entity)))
            (when (typep constraint 'frame-constraint)
              (relax constraint half-delta T))))))))
