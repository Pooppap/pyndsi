'''
(*)~----------------------------------------------------------------------------------
 Pupil - eye tracking platform
 Copyright (C) 2012-2015  Pupil Labs

 Distributed under the terms of the CC BY-NC-SA License.
 License details are in the file LICENSE, distributed as part of this software.
----------------------------------------------------------------------------------~(*)
'''

cimport cturbojpeg as turbojpeg

import struct
import json as serial
import traceback as tb
import numpy as np
import zmq

import logging
logger = logging.getLogger(__name__)

from . import StreamError

from .frame cimport JEPGFrame
from .frame import VIDEO_FRAME_HEADER_FMT, VIDEO_FRAME_FORMAT_MJPEG


class NotDataSubSupportedError(Exception):
    def __init__(self, value=None):
        self.value = value or 'This sensor does not support data subscription.'
    def __str__(self):
        return repr(self.value)

cdef class Sensor(object):

    def __cinit__(self, *args, **kwargs):
        pass

    def __init__(self,
            host_uuid,
            host_name,
            sensor_uuid,
            sensor_name,
            sensor_type,
            notify_endpoint,
            command_endpoint,
            data_endpoint=None,
            context=None,
            callbacks=()):
        self.tj_context = turbojpeg.tjInitDecompress()
        self.callbacks = [self.on_notification]+list(callbacks)
        self.context = context or zmq.Context()
        self.host_uuid = host_uuid
        self.host_name = host_name
        self.name = sensor_name
        self.type = sensor_type
        self.uuid = sensor_uuid
        self.notify_endpoint = notify_endpoint
        self.command_endpoint = command_endpoint
        self.data_endpoint = data_endpoint
        self.controls = {}

        self.notify_sub = context.socket(zmq.SUB)
        self.notify_sub.connect(self.notify_endpoint)
        self.notify_sub.subscribe(self.uuid)

        self.command_push = context.socket(zmq.PUSH)
        self.command_push.connect(self.command_endpoint)

        if self.data_endpoint:
            self.data_sub = context.socket(zmq.SUB)
            self.data_sub.set_hwm(3)
            self.data_sub.connect(self.data_endpoint)
            self.data_sub.subscribe(self.uuid)
        else:
            self.data_sub = None

        self.refresh_controls()

    def unlink(self):
        self.notify_sub.unsubscribe(self.uuid)
        self.notify_sub.close(linger=0)
        self.command_push.close(linger=0)
        if self.supports_data_subscription:
            self.data_sub.unsubscribe(self.uuid)
            self.data_sub.close(linger=0)

    def __del__(self):
        logger.debug('Sensor deleted: {}'.format(self))
        self.unlink()

    property supports_data_subscription:
        def __get__(self):
            return bool(self.data_sub)

    property has_notifications:
        def __get__(self):
            has_n = self.notify_sub.get(zmq.EVENTS) & zmq.POLLIN
            return has_n

    property has_data:
        def __get__(self):
            try:
                return self.data_sub.get(zmq.EVENTS) & zmq.POLLIN
            except AttributeError:
                raise NotDataSubSupportedError()

    def __str__(self):
        return '<{} {}@{} [{}]>'.format(__name__, self.name, self.host_name, self.type)

    def handle_notification(self):
        raw_notification = self.notify_sub.recv_multipart()
        if len(raw_notification) != 2:
            logger.debug('Message for sensor {} has not correct amount of frames: {}'.format(self.uuid,raw_notification))
            return
        sender_id = raw_notification[0].decode()
        notification_payload = raw_notification[1]
        try:
            if sender_id != self.uuid:
                raise ValueError('Message was destined for {} but was recieved by {}'.format(sender_id, self.uuid))
            notification = serial.loads(notification_payload)
            notification['subject']
        except serial.decoder.JSONDecodeError:
            logger.debug('JSONDecodeError for payload: `{}`'.format(notification_payload))
        except Exception:
            logger.debug(tb.format_exc())
        else:
            try:
                self.execute_callbacks(notification)
            except:
                logger.debug(tb.format_exc())

    def execute_callbacks(self, event):
        for callback in self.callbacks:
            callback(self, event)

    def on_notification(self, caller, notification):
        if notification['subject'] == 'update':
            class UnsettableDict(dict):
                def __getitem__(self, key):
                    return self.get(key)
                def __setitem__(self, key, value):
                    raise ValueError('Dictionary is read-only. Use Sensor.set_control_value instead.')

            ctrl_id_key = notification['control_id']
            if ctrl_id_key in self.controls:
                self.controls[ctrl_id_key].update(UnsettableDict(notification['changes']))
            else: self.controls[ctrl_id_key] = UnsettableDict(notification['changes'])
        elif notification['subject'] == 'remove':
            try:
                del self.controls[notification['control_id']]
            except KeyError:
                pass

    def get_data(self,copy=True):
        try:
            return self.data_sub.recv_multipart(copy=copy)
        except AttributeError:
            raise NotDataSubSupportedError()

    def get_newest_data_frame(self, timeout=None):
        if not self.supports_data_subscription:
            raise NotDataSubSupportedError()

        # blocks until new frame arrives or times out
        cdef JEPGFrame frame
        if self.data_sub.poll(timeout=timeout):
            #while self.has_data:
            # skip to newest frame
            data_msg = self.get_data(copy=True)
            meta_data = struct.unpack("<LLLLQLL", data_msg[1])
            if meta_data[0] == VIDEO_FRAME_FORMAT_MJPEG:
                frame = JEPGFrame(*meta_data, zmq_frame=data_msg[2], check_hash=True)
                frame.attach_tj_context(self.tj_context)
            else:
                raise StreamError('Frame was not of format MJPEG')
            return frame
        else:
            raise StreamError('Operation timed out.')

    def refresh_controls(self):
        cmd = serial.dumps({'action': 'refresh_controls'})
        self.command_push.send_string(self.uuid, flags=zmq.SNDMORE)
        self.command_push.send_string(cmd)

    def reset_all_control_values(self):
        for control_id in self.controls:
            self.reset_control_value(control_id)

    def reset_control_value(self, control_id):
        if control_id in self.controls:
            if 'def' in self.controls[control_id]:
                value = self.controls[control_id]['def']
                self.set_control_value(control_id, value)
            else:
                logger.error(('Could not reset control `{}` because it does not have a default value.').format(control_id))
        else: logger.error('Could not reset unknown control `{}`'.format(control_id))

    def set_control_value(self, control_id, value):
        try:
            dtype = self.controls[control_id]['dtype']
            if dtype == 'bool': value = bool(value)
            elif dtype == 'string': value = str(value)
            elif dtype == 'integer': value = int(value)
            elif dtype == 'float': value = float(value)
            elif dtype == 'intmapping': value = int(value)
            elif dtype == 'strmapping': value = str(value)
        except KeyError:
            pass
        cmd = serial.dumps({
            "action": "set_control_value",
            "control_id": control_id,
            "value": value})
        self.command_push.send_string(self.uuid, flags=zmq.SNDMORE)
        self.command_push.send_string(cmd)
